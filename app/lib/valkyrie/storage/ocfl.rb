# frozen_string_literal: true

module Valkyrie
  module Storage
    # OCFL 1.1 storage adapter.
    #
    # Two ID forms, both matched by handles?:
    #   id         = ocfl://<tag>/@<root>/<key>/<logical-path>      (head)
    #   version_id = ocfl://<tag>/@<root>/<key>/<vN>/<logical-path> (per-version)
    #
    # <root> names which storage root holds the object, so the pool an adapter
    # spans can grow without any stored id changing. It is a name, never a
    # location. A NOID cannot contain '@', so the segment is unambiguous, and an
    # id lacking it resolves to this adapter's root.
    #
    # <tag> claims ids for this adapter. Pass it explicitly: derived from
    # base_path it binds every stored id to a physical location, so the storage
    # could never move without every id in Postgres ceasing to resolve.
    class OCFL
      PROTOCOL = 'ocfl://'
      INVENTORY_FILENAME = 'inventory.json'
      OBJECT_NAMASTE = '0=ocfl_object_1.1'
      SIDECAR_SUFFIX = '.sha512'
      # OCFL spec W005 says inventory `id` SHOULD be a URI. We use a locally-
      # scoped URN keyed on NOID so the id stays bound to the durable layer
      # (NOID, encoded in the path) rather than to a hostname or to Postgres.
      INVENTORY_ID_NAMESPACE = 'urn:neu-drs'
      # Characters an SMB-backed mount rejects, plus the control range.
      ILLEGAL_PATH_CHARS = /[<>:"|?*\x00-\x1f]/
      RESERVED_STEMS = /\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\z/i
      MAX_SEGMENT_BYTES = 200
      # Sentinel for an id naming a root this adapter does not hold; distinct
      # from nil, which means the id named no root at all.
      FOREIGN_ROOT = :foreign_root
      # Our local extension. The spec reserves `extensions/<name>/` for exactly
      # this, and forbids loose files directly under `extensions`.
      POOL_EXTENSION = 'neu-drs-storage-pool'
      SEAL_FILENAME = 'sealed.json'
      POOL_CONFIG_FILENAME = 'config.json'

      # Every root is sealed, so a new object has nowhere to go. An operator
      # opens another root; the adapter must not pick a sealed one.
      PoolSealed = Class.new(StandardError)
      # One key exists in two roots. That is a failed migration, and picking
      # either one silently would make the wrong half authoritative.
      AmbiguousObject = Class.new(StandardError)

      attr_reader :storage_roots, :pool_name, :file_mover, :clock, :user_agent, :digest_algorithm

      # Holds one root or several. `storage_roots:` is an ordered name => path
      # map; `storage_root:` with `root_name:` is the one-root spelling of the
      # same thing. A name is a name and never a location, so a root can move
      # between mounts or providers without any stored id changing.
      def initialize(storage_root: nil,
                     storage_roots: nil,
                     tag: nil,
                     root_name: 'r001',
                     pool_name: 'drs',
                     digest_algorithm: 'sha512',
                     tuple_sizes: [2, 2],
                     file_mover: FileUtils.method(:mv),
                     clock: Time.method(:now),
                     user_agent: { name:    'Atlas',
                                   address: 'mailto:library-systems@northeastern.edu' })
        @storage_roots = build_roots(storage_root, storage_roots, root_name, tuple_sizes)
        @pool_name = pool_name
        @tag = tag
        @digest_algorithm = digest_algorithm
        @file_mover = file_mover
        @clock = clock
        @user_agent = user_agent.transform_keys(&:to_s)
      end

      # The root a new object lands in when nothing else decides. Placement
      # refines this; a read never uses it, because a read is told its root.
      def default_root_name
        storage_roots.keys.first
      end

      def protocol
        PROTOCOL
      end

      # Falls back to a digest of the first root's path only so an adapter built
      # without a tag still works; a configured adapter names its tag.
      def tag
        @tag ||= Digest::SHA1.hexdigest(storage_roots.values.first.base_path.to_s)[0..7]
      end

      def handles?(id:)
        id.to_s.start_with?("#{PROTOCOL}#{tag}/")
      end

      def supports?(feature)
        feature == :versions
      end

      def upload(file:, original_filename:, resource:, **_extra)
        upload_many(files: [{ file: file, original_filename: original_filename }], resource: resource).first
      end

      # Commits several files as ONE version. A version is OCFL's unit of change
      # and holds any number of logical paths, so files written together — a
      # resource's envelope, say — belong in one version rather than one each.
      # Answers a File per entry, in the order given.
      def upload_many(files:, resource:, **_extra)
        # An empty batch would cut a version identical to the one before it, which
        # is churn recording nothing.
        raise ArgumentError, 'upload_many needs at least one file' if Array(files).empty?

        key = resolve_key(resource)
        sources = Array(files).map do |entry|
          { source: entry.fetch(:file), logical_path: sanitize_filename(entry.fetch(:original_filename)) }
        end
        perform_upload(root_name: root_for_new_write(key), key: key, sources: sources)
      end

      def upload_version(id:, file:)
        parsed = parse_id(id)
        raise Valkyrie::StorageAdapter::FileNotFound unless parsed

        perform_upload(root_name: parsed[:root], key: parsed[:key],
                       sources: [{ source: file, logical_path: parsed[:logical_path] }]).first
      end

      def sealed?(root_name)
        seal_marker_path(root_name).exist?
      end

      # Seals a root against *new objects only*. It keeps serving every read and
      # keeps accepting new versions of the objects it already holds, which is
      # what lets the pool grow without a single object moving.
      def seal!(root_name, reason: nil)
        bootstrap_root!(root_name)
        path = seal_marker_path(root_name)
        FileUtils.mkdir_p(path.dirname)
        ::File.write(path, JSON.pretty_generate('sealed_at' => clock.call.utc.iso8601,
                                                'reason'    => reason))
        root_name
      end

      # The root a new object lands in: the first one not sealed. Which root is
      # open therefore lives on the disk beside the content rather than in
      # config, so it survives a restart and an operator can read it off a
      # backup.
      def open_root_name
        storage_roots.keys.find { |name| !sealed?(name) } ||
          raise(PoolSealed, "every storage root is sealed: #{storage_roots.keys.join(', ')}")
      end

      def find_by(id:)
        parsed = parse_id(id)
        raise Valkyrie::StorageAdapter::FileNotFound unless parsed

        object_root = object_root_for(parsed)
        raise Valkyrie::StorageAdapter::FileNotFound unless object_root.exist?

        inventory = load_inventory(object_root: object_root, version: parsed[:version])
        raise Valkyrie::StorageAdapter::FileNotFound unless inventory

        version = parsed[:version] || inventory.head
        digest = inventory.digest_for(version: version, logical_path: parsed[:logical_path])
        raise Valkyrie::StorageAdapter::FileNotFound unless digest

        content_path = inventory.content_path_for(digest)
        raise Valkyrie::StorageAdapter::FileNotFound unless content_path

        physical = object_root.join(content_path)
        raise Valkyrie::StorageAdapter::FileNotFound unless physical.exist?

        build_file(root_name: parsed[:root], key: parsed[:key], version: version,
                   logical_path: parsed[:logical_path], physical: physical)
      end

      def find_versions(id:)
        parsed = parse_id(id)
        return [] unless parsed

        object_root = object_root_for(parsed)
        return [] unless object_root.exist?

        inventory = load_inventory(object_root: object_root)
        return [] unless inventory

        inventory.versions_containing(parsed[:logical_path]).map do |v|
          digest = inventory.digest_for(version: v, logical_path: parsed[:logical_path])
          content_path = inventory.content_path_for(digest)
          physical = object_root.join(content_path)
          build_file(root_name: parsed[:root], key: parsed[:key], version: v,
                     logical_path: parsed[:logical_path], physical: physical)
        end
      end

      # Like find_versions, but returns the inventory's per-version metadata
      # (created / message / user) instead of File handles — the bits needed
      # to describe a version's provenance without reading its bytes. Newest
      # first, same ordering as find_versions. Each element is a hash:
      #   { version: 'v3', created: <iso8601>, message:, user:, digest: }
      #
      # `digest` is the content digest of the logical path *in that version*.
      # Note OCFL state is cumulative: a write to any OTHER logical path in the
      # same object cuts a new version that still lists this path (carried
      # forward, unchanged digest). So consecutive entries can share a digest
      # even though this path was not re-written — callers wanting "distinct
      # content states" coalesce on `digest` rather than trusting the count.
      def find_version_metadata(id:)
        parsed = parse_id(id)
        return [] unless parsed

        inventory = object_inventory(parsed[:root], parsed[:key])
        return [] unless inventory

        inventory.versions_containing(parsed[:logical_path]).map do |v|
          { version: v }.merge(version_facts(inventory, v, parsed[:logical_path]))
        end
      end

      # Per-version metadata for a set of specific ids, keyed by id string:
      #   { 'ocfl://<tag>/@<root>/<key>/v1/a.txt' => { version: 'v1', created:,
      #                                                message:, user:, digest: } }
      #
      # find_version_metadata answers "every version holding ONE logical path".
      # This answers "the recorded facts for exactly these ids", where each id
      # names its own version AND its own logical path. A binary's revision
      # history needs the second question: a replacement can land under a
      # different logical path than the current one, and a lookup keyed on the
      # current path then reports nothing for the superseded revisions.
      #
      # One inventory read per object, because an OCFL inventory is cumulative —
      # the head inventory holds the state of every version. Ids the adapter
      # doesn't handle, or that name a version the object has no record of, are
      # absent from the result.
      def find_version_metadata_for(ids:)
        parsed = Array(ids).to_h { |id| [id.to_s, parse_id(id)] }.compact
        parsed.group_by { |_id, fields| fields.values_at(:root, :key) }
              .each_with_object({}) do |((root, key), entries), result|
          inventory = object_inventory(root, key)
          next unless inventory

          entries.each do |id, fields|
            version = fields[:version] || inventory.head
            next unless inventory.versions.key?(version)

            result[id] = { version: version }.merge(version_facts(inventory, version, fields[:logical_path]))
          end
        end
      end

      # The recorded content digest for a stored id, read straight from the
      # inventory — no byte re-hash. Returns { algorithm:, value: } or nil when
      # the id doesn't resolve. Lets callers expose/compare fixity cheaply
      # (reconciliation at TB scale) without streaming the bytes back down.
      def digest_for(id:)
        parsed = parse_id(id)
        return nil unless parsed

        object_root = object_root_for(parsed)
        return nil unless object_root.exist?

        inventory = load_inventory(object_root: object_root, version: parsed[:version])
        return nil unless inventory

        version = parsed[:version] || inventory.head
        value = inventory.digest_for(version: version, logical_path: parsed[:logical_path])
        return nil unless value

        { algorithm: inventory.digest_algorithm, value: value }
      end

      # The OCFL version label (vN) a stored id names, or nil when the id carries
      # no version segment or this adapter does not handle it. Callers needing
      # the label come through here: the id grammar belongs to the adapter, and a
      # second parser elsewhere drifts from it.
      def version_label_for(id)
        parsed = parse_id(id)
        parsed && parsed[:version]
      end

      # Removes the whole OCFL object for the key the id names — every version
      # and every logical path, not only the path in the id. Atlas keys one
      # object per resource NOID, so an object and a resource's bytes are the
      # same extent, and a partial removal would leave an object whose
      # inventory no longer describes its contents.
      def delete(id:)
        parsed = parse_id(id)
        return unless parsed

        delete_object(key: parsed[:key])
      end

      # The same removal addressed by NOID instead of by a stored file id.
      # Every resource owns an object (its preservation envelope) even when it
      # holds no binary, and that object's id appears nowhere in the metadata
      # for a caller to pass to delete.
      #
      # A NOID names no root, so this searches the pool. That is one existence
      # check per root, and removal is rare.
      def delete_object(key:)
        return if key.blank?

        root_name = existing_root_name(key.to_s)
        return if root_name.nil?

        FileUtils.rm_rf(storage_roots.fetch(root_name).object_root_for(key.to_s))
      end

      private

        # An object never spans roots, so a write goes where the object already is
        # and only a genuinely new object follows placement. Without this lookup
        # a resource's MODS blob and its binary can land in different roots, and
        # each root's inventory then describes half an object — a state no OCFL
        # validator can detect, because each half is valid on its own.
        def root_for_new_write(key)
          existing_root_name(key) || open_root_name
        end

        # Which root already holds this key's object, or nil for a new one.
        def existing_root_name(key)
          holding = storage_roots.select { |_name, root| root.object_root_for(key).exist? }.keys
          if holding.size > 1
            raise AmbiguousObject, "#{key} exists in more than one storage root: #{holding.join(', ')}"
          end

          holding.first
        end

        def bootstrap_root!(name)
          root = storage_roots.fetch(name)
          root.bootstrap!
          write_pool_descriptor!(name)
          root
        end

        # Records the pool inside each root, so somebody who finds one root
        # learns the others exist and what they are called. A config file can be
        # lost; this cannot be lost without losing the content with it. Rewritten
        # whenever the roster stops matching, so adding a root heals the siblings
        # list on the next write rather than leaving every root describing an
        # older pool.
        def write_pool_descriptor!(name)
          path = pool_config_path(name)
          desired = { 'extensionName' => POOL_EXTENSION, 'pool' => pool_name,
                      'root' => name, 'siblings' => storage_roots.keys - [name] }
          return if recorded_descriptor(path).slice(*desired.keys) == desired

          FileUtils.mkdir_p(path.dirname)
          ::File.write(path, JSON.pretty_generate(desired.merge('written' => clock.call.utc.iso8601)))
        end

        def recorded_descriptor(path)
          path.exist? ? JSON.parse(path.read) : {}
        rescue JSON::ParserError
          {}
        end

        def pool_extension_dir(root_name)
          storage_roots.fetch(root_name).base_path.join('extensions', POOL_EXTENSION)
        end

        def pool_config_path(root_name)
          pool_extension_dir(root_name).join(POOL_CONFIG_FILENAME)
        end

        def seal_marker_path(root_name)
          pool_extension_dir(root_name).join(SEAL_FILENAME)
        end

        def resolve_key(resource)
          if resource.respond_to?(:noid) && resource.noid.present?
            resource.noid
          else
            resource.id.to_s
          end
        end

        # The head inventory of the object holding `key`, or nil when the object
        # has no readable inventory.
        def object_inventory(root_name, key)
          object_root = storage_roots.fetch(root_name).object_root_for(key)
          return nil unless object_root.exist?

          load_inventory(object_root: object_root)
        end

        # The on-disk object a parsed id points at. parse_id already refused a
        # root this adapter does not hold, so the fetch cannot miss.
        def object_root_for(parsed)
          storage_roots.fetch(parsed[:root]).object_root_for(parsed[:key])
        end

        def build_roots(single, many, root_name, tuple_sizes)
          pairs = many.presence || { root_name => single }
          # Not blank?: Pathname#empty? asks whether the directory on disk is
          # empty, and blank? delegates to it, so an empty storage root — every
          # freshly mounted one — would read as no root at all.
          raise ArgumentError, 'give storage_root: or storage_roots:' if pairs.values.any? { |path| path.to_s.empty? }

          pairs.to_h do |name, path|
            validate_root_name!(name)
            [name.to_s, StorageRoot.new(base_path: Pathname.new(path), tuple_sizes: tuple_sizes)]
          end
        end

        # A name holding '/' or '@' would break the very grammar the name exists
        # to disambiguate.
        def validate_root_name!(name)
          return unless name.to_s.empty? || name.to_s.match?(%r{[/@]})

          raise ArgumentError, "root name must be a name, not a path: #{name.inspect}"
        end

        # The inventory's record of one logical path at one version. `digest` is
        # the content digest of that path *in that version*, so it is the fixity
        # value as recorded then, not a re-hash of the bytes now.
        def version_facts(inventory, version, logical_path)
          meta = inventory.versions[version] || {}
          { created: meta['created'], message: meta['message'], user: meta['user'],
            digest: inventory.digest_for(version: version, logical_path: logical_path) }
        end

        def inventory_id_for(key)
          "#{INVENTORY_ID_NAMESPACE}:#{key}"
        end

        # The deposited filename becomes a logical path in the inventory and a
        # real directory entry, so it has to survive any substrate we might store
        # on. We flatten to one segment — a directory component would let a
        # deposit escape its object — and drop what an SMB-backed mount rejects.
        # Non-ASCII stays, NFC normalised, because an accented filename is
        # descriptive metadata a reader needs.
        def sanitize_filename(name)
          base = ::File.basename(name.to_s.tr('\\', '/')).scrub('_')
          base = base.unicode_normalize(:nfc).gsub(ILLEGAL_PATH_CHARS, '_').sub(/[. ]+\z/, '')
          base = "_#{base}" if RESERVED_STEMS.match?(base.sub(/\..*\z/, ''))
          base = truncate_segment(base)
          base.empty? ? 'file' : base
        end

        # Keep the extension when trimming to a portable component length: the
        # deposit path reads it back as the MIME hint.
        def truncate_segment(base)
          return base if base.bytesize <= MAX_SEGMENT_BYTES

          ext = ::File.extname(base)
          stem = base[0, base.length - ext.length].to_s
          "#{stem.byteslice(0, MAX_SEGMENT_BYTES - ext.bytesize).to_s.scrub('')}#{ext}"
        end

        # id forms:
        #   ocfl://<tag>/@<root>/<key>/<logical-path...>
        #   ocfl://<tag>/@<root>/<key>/vN/<logical-path...>
        #
        # An absent @<root> resolves to this adapter's root, so an id minted
        # before the segment existed still reads. A root this adapter does not
        # hold is not ours to resolve, so it parses as nothing and the callers'
        # existing guards answer FileNotFound.
        def parse_id(id)
          str = id.to_s
          return nil unless str.start_with?("#{PROTOCOL}#{tag}/")

          parts = str.sub("#{PROTOCOL}#{tag}/", '').split('/', -1)
          root = take_root!(parts)
          return nil if root == FOREIGN_ROOT || parts.size < 2

          key = parts.shift
          version = parts.shift if parts.first =~ /\Av\d+\z/
          logical_path = parts.join('/')
          return nil if logical_path.empty?

          { root: root, key: key, version: version, logical_path: logical_path }
        end

        # Consumes a leading @<root> segment when there is one. Answers the root
        # name, or FOREIGN_ROOT for a root this adapter does not hold.
        def take_root!(parts)
          return default_root_name unless parts.first.to_s.start_with?('@')

          named = parts.shift.delete_prefix('@')
          storage_roots.key?(named) ? named : FOREIGN_ROOT
        end

        def logical_id_for(root_name, key, logical_path)
          "#{PROTOCOL}#{tag}/@#{root_name}/#{key}/#{logical_path}"
        end

        def version_id_for(root_name, key, version, logical_path)
          "#{PROTOCOL}#{tag}/@#{root_name}/#{key}/#{version}/#{logical_path}"
        end

        # The root belongs in the id because the caller persists this id and
        # reads it back later. Stamping the default root here would hand out an
        # id pointing at a root that does not hold the object.
        def build_file(root_name:, key:, version:, logical_path:, physical:)
          OCFL::File.new(
            id:         Valkyrie::ID.new(logical_id_for(root_name, key, logical_path)),
            version_id: Valkyrie::ID.new(version_id_for(root_name, key, version, logical_path)),
            io:         LazyFile.open(physical.to_s, 'rb')
          )
        end

        # One version per call, however many sources it carries. Each source is a
        # { source:, logical_path: } pair.
        def perform_upload(root_name:, key:, sources:)
          root = bootstrap_root!(root_name)
          object_root = root.object_root_for(key)
          bootstrap_object!(object_root)

          base_inventory = load_inventory(object_root: object_root) ||
                           Inventory.empty(id: inventory_id_for(key), digest_algorithm: digest_algorithm)

          next_n = base_inventory.head_int + 1
          next_v = "v#{next_n}"
          entries = digested_entries(sources, next_v)

          new_inventory = base_inventory.bump(
            entries: entries.map { |e| e.slice(:digest, :logical_path, :content_path) },
            created: clock.call.utc.iso8601,
            message: 'Atlas upload',
            user:    user_agent
          )

          tmp_dir = stage_version_dir(object_root, next_n)
          stage_content(entries, tmp_dir, base_inventory)

          inv_json = pretty_inventory_json(new_inventory)
          ::File.write(tmp_dir.join(INVENTORY_FILENAME), inv_json)
          ::File.write(tmp_dir.join("#{INVENTORY_FILENAME}#{SIDECAR_SUFFIX}"), sidecar_body(inv_json))
          fsync_staged!(tmp_dir)

          version_dir = object_root.join(next_v)
          FileUtils.mv(tmp_dir.to_s, version_dir.to_s)
          fsync_dir(object_root)

          update_head_pointer(object_root, inv_json)

          entries.map do |entry|
            physical = object_root.join(new_inventory.content_path_for(entry[:digest]))
            build_file(root_name: root_name, key: key, version: next_v,
                       logical_path: entry[:logical_path], physical: physical)
          end
        end

        def digested_entries(sources, next_v)
          sources.map do |source|
            io = unwrap_source(source.fetch(:source))
            io.rewind if io.respond_to?(:rewind)
            digest = stream_digest(io)
            io.rewind if io.respond_to?(:rewind)
            logical_path = source.fetch(:logical_path)
            { digest: digest, logical_path: logical_path, io: io,
              content_path: "#{next_v}/content/#{logical_path}" }
          end
        end

        # Skips a digest the object already holds, and a digest an earlier entry
        # in this batch just staged: identical bytes under two names are one
        # content file that both logical paths point at.
        def stage_content(entries, tmp_dir, base_inventory)
          staged = Set.new
          entries.each do |entry|
            next if base_inventory.dedup?(entry[:digest]) || staged.include?(entry[:digest])

            staged << entry[:digest]
            target = tmp_dir.join('content', entry[:logical_path])
            FileUtils.mkdir_p(target.dirname)
            move_or_copy(entry[:io], target)
          end
        end

        def bootstrap_object!(object_root)
          FileUtils.mkdir_p(object_root)
          namaste = object_root.join(OBJECT_NAMASTE)
          ::File.write(namaste, "ocfl_object_1.1\n") unless namaste.exist?
        end

        def stage_version_dir(object_root, version_number)
          tmp = object_root.join(".tmp-v#{version_number}-#{SecureRandom.hex(4)}")
          FileUtils.mkdir_p(tmp)
          tmp
        end

        def move_or_copy(io, target)
          if io.respond_to?(:path) && io.path && ::File.exist?(io.path)
            file_mover.call(io.path, target.to_s)
          else
            ::File.open(target, 'wb') { |f| IO.copy_stream(io, f) }
          end
        end

        # Per the plan: per-version vN/inventory.json (committed atomically by
        # the tmp-dir rename) is authoritative. Head pair at the object root is
        # convenience. No single-rename ordering preserves
        # sha512(inventory.json) == read(sidecar) across both renames; readers
        # verify and fall back to highest vN on mismatch.
        def update_head_pointer(object_root, inv_json)
          tmp_inv = object_root.join('tmp_inventory.json')
          tmp_sidecar = object_root.join("tmp_inventory.json#{SIDECAR_SUFFIX}")
          ::File.write(tmp_inv, inv_json)
          ::File.write(tmp_sidecar, sidecar_body(inv_json))
          fsync_file(tmp_inv)
          fsync_file(tmp_sidecar)
          FileUtils.mv(tmp_inv.to_s, object_root.join(INVENTORY_FILENAME).to_s)
          FileUtils.mv(tmp_sidecar.to_s, object_root.join("#{INVENTORY_FILENAME}#{SIDECAR_SUFFIX}").to_s)
          fsync_dir(object_root)
        end

        # When version: is given, read vN/inventory.json directly. Otherwise
        # try the head pair; if it fails its sidecar check, fall back to the
        # highest vN/inventory.json (authoritative).
        def load_inventory(object_root:, version: nil)
          path =
            if version
              object_root.join(version, INVENTORY_FILENAME)
            else
              head_inventory_path(object_root)
            end
          return nil unless path&.exist?

          Inventory.parse(::File.read(path))
        rescue JSON::ParserError
          nil
        end

        def head_inventory_path(object_root)
          head = object_root.join(INVENTORY_FILENAME)
          sidecar = object_root.join("#{INVENTORY_FILENAME}#{SIDECAR_SUFFIX}")
          if head.exist? && sidecar.exist? && head_pair_consistent?(head, sidecar)
            head
          else
            highest_version_inventory_path(object_root)
          end
        end

        def head_pair_consistent?(head, sidecar)
          actual = Digest::SHA512.file(head.to_s).hexdigest
          recorded = ::File.read(sidecar).split(/\s+/, 2).first
          actual == recorded
        rescue Errno::ENOENT
          false
        end

        def highest_version_inventory_path(object_root)
          versions = object_root.children.select do |c|
            c.directory? && c.basename.to_s =~ /\Av\d+\z/
          end
          return nil if versions.empty?

          versions.max_by { |v| v.basename.to_s.delete_prefix('v').to_i }.join(INVENTORY_FILENAME)
        end

        def stream_digest(io)
          digest = Digest::SHA512.new
          while (chunk = io.read(65_536))
            digest.update(chunk)
          end
          digest.hexdigest
        end

        def unwrap_source(source)
          if source.is_a?(Valkyrie::StorageAdapter::File)
            source.io
          else
            source
          end
        end

        def pretty_inventory_json(inventory)
          JSON.pretty_generate(inventory.to_h)
        end

        def sidecar_body(inv_json)
          "#{Digest::SHA512.hexdigest(inv_json)}  #{INVENTORY_FILENAME}\n"
        end

        # A rename publishes a version atomically, but atomic is not durable:
        # the kernel can lose the bytes after the call returns, leaving Postgres
        # recording a version the preservation copy does not hold. Force the
        # staged tree down before the rename and the parent directory down after
        # it. A substrate that cannot fsync raises rather than pretend.
        def fsync_staged!(dir)
          Pathname.glob(dir.join('**', '*')).each do |path|
            path.directory? ? fsync_dir(path) : fsync_file(path)
          end
          fsync_dir(dir)
        end

        def fsync_file(path)
          ::File.open(path.to_s, 'rb', &:fsync)
        end

        # Ruby 3.0 carries no Dir#fsync and no File::DIRECTORY, but File.open on
        # a directory yields a descriptor that fsync accepts.
        def fsync_dir(path)
          ::File.open(path.to_s, &:fsync)
        end
    end
  end
end
