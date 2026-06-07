# frozen_string_literal: true

module Valkyrie
  module Storage
    # OCFL 1.1 storage adapter.
    #
    # Two ID forms, both matched by handles?:
    #   id         = ocfl://<tag>/<key>/<logical-path>         (head)
    #   version_id = ocfl://<tag>/<key>/<vN>/<logical-path>    (per-version)
    #
    # <tag> is sha1(base_path)[0..7] so multiple OCFL roots can register
    # without colliding.
    class OCFL
      PROTOCOL = 'ocfl://'
      INVENTORY_FILENAME = 'inventory.json'
      SIDECAR_SUFFIX = '.sha512'
      # OCFL spec W005 says inventory `id` SHOULD be a URI. We use a locally-
      # scoped URN keyed on NOID so the id stays bound to the durable layer
      # (NOID, encoded in the path) rather than to a hostname or to Postgres.
      INVENTORY_ID_NAMESPACE = 'urn:neu-drs'

      attr_reader :storage_root, :file_mover, :clock, :user_agent, :digest_algorithm

      def initialize(storage_root:,
                     digest_algorithm: 'sha512',
                     tuple_sizes: [2, 2],
                     file_mover: FileUtils.method(:mv),
                     clock: Time.method(:now),
                     user_agent: { name:    'Atlas',
                                   address: 'mailto:library-systems@northeastern.edu' })
        @storage_root_path = Pathname.new(storage_root)
        @digest_algorithm = digest_algorithm
        @file_mover = file_mover
        @clock = clock
        @user_agent = user_agent.transform_keys(&:to_s)
        @storage_root = StorageRoot.new(base_path: @storage_root_path, tuple_sizes: tuple_sizes)
      end

      def protocol
        PROTOCOL
      end

      def tag
        @tag ||= Digest::SHA1.hexdigest(@storage_root_path.to_s)[0..7]
      end

      def handles?(id:)
        id.to_s.start_with?("#{PROTOCOL}#{tag}/")
      end

      def supports?(feature)
        feature == :versions
      end

      def upload(file:, original_filename:, resource:, **_extra)
        key = resolve_key(resource)
        perform_upload(key: key, source: file, logical_path: sanitize_filename(original_filename))
      end

      def upload_version(id:, file:)
        parsed = parse_id(id)
        raise Valkyrie::StorageAdapter::FileNotFound unless parsed

        perform_upload(key: parsed[:key], source: file, logical_path: parsed[:logical_path])
      end

      def find_by(id:)
        parsed = parse_id(id)
        raise Valkyrie::StorageAdapter::FileNotFound unless parsed

        object_root = storage_root.object_root_for(parsed[:key])
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

        build_file(key: parsed[:key], version: version, logical_path: parsed[:logical_path], physical: physical)
      end

      def find_versions(id:)
        parsed = parse_id(id)
        return [] unless parsed

        object_root = storage_root.object_root_for(parsed[:key])
        return [] unless object_root.exist?

        inventory = load_inventory(object_root: object_root)
        return [] unless inventory

        inventory.versions_containing(parsed[:logical_path]).map do |v|
          digest = inventory.digest_for(version: v, logical_path: parsed[:logical_path])
          content_path = inventory.content_path_for(digest)
          physical = object_root.join(content_path)
          build_file(key: parsed[:key], version: v, logical_path: parsed[:logical_path], physical: physical)
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

        object_root = storage_root.object_root_for(parsed[:key])
        return [] unless object_root.exist?

        inventory = load_inventory(object_root: object_root)
        return [] unless inventory

        inventory.versions_containing(parsed[:logical_path]).map do |v|
          meta = inventory.versions[v] || {}
          { version: v, created: meta['created'], message: meta['message'], user: meta['user'],
            digest: inventory.digest_for(version: v, logical_path: parsed[:logical_path]) }
        end
      end

      def delete(id:)
        parsed = parse_id(id)
        return unless parsed

        object_root = storage_root.object_root_for(parsed[:key])
        FileUtils.rm_rf(object_root) if object_root.exist?
      end

      private

        def resolve_key(resource)
          if resource.respond_to?(:noid) && resource.noid.present?
            resource.noid
          else
            resource.id.to_s
          end
        end

        def inventory_id_for(key)
          "#{INVENTORY_ID_NAMESPACE}:#{key}"
        end

        def sanitize_filename(name)
          parts = name.to_s.split('/').reject { |p| p.empty? || p == '..' || p == '.' }
          parts.empty? ? 'file' : parts.join('/')
        end

        # id forms:
        #   ocfl://<tag>/<key>/<logical-path...>
        #   ocfl://<tag>/<key>/vN/<logical-path...>
        def parse_id(id)
          str = id.to_s
          return nil unless str.start_with?("#{PROTOCOL}#{tag}/")

          remainder = str.sub("#{PROTOCOL}#{tag}/", '')
          parts = remainder.split('/', -1)
          return nil if parts.size < 2

          key = parts.shift
          version = nil
          version = parts.shift if parts.first =~ /\Av\d+\z/
          logical_path = parts.join('/')
          return nil if logical_path.empty?

          { key: key, version: version, logical_path: logical_path }
        end

        def logical_id_for(key, logical_path)
          "#{PROTOCOL}#{tag}/#{key}/#{logical_path}"
        end

        def version_id_for(key, version, logical_path)
          "#{PROTOCOL}#{tag}/#{key}/#{version}/#{logical_path}"
        end

        def build_file(key:, version:, logical_path:, physical:)
          OCFL::File.new(
            id:         Valkyrie::ID.new(logical_id_for(key, logical_path)),
            version_id: Valkyrie::ID.new(version_id_for(key, version, logical_path)),
            io:         LazyFile.open(physical.to_s, 'rb')
          )
        end

        def perform_upload(key:, source:, logical_path:)
          storage_root.bootstrap!
          object_root = storage_root.object_root_for(key)
          bootstrap_object!(object_root)

          io = unwrap_source(source)
          io.rewind if io.respond_to?(:rewind)
          digest = stream_digest(io)
          io.rewind if io.respond_to?(:rewind)

          base_inventory = load_inventory(object_root: object_root) ||
                           Inventory.empty(id: inventory_id_for(key), digest_algorithm: digest_algorithm)

          next_n = base_inventory.head_int + 1
          next_v = "v#{next_n}"
          content_path = "#{next_v}/content/#{logical_path}"

          new_inventory = base_inventory.bump(
            digest:       digest,
            logical_path: logical_path,
            content_path: content_path,
            created:      clock.call.utc.iso8601,
            message:      'Atlas upload',
            user:         user_agent
          )

          dedup = base_inventory.dedup?(digest)
          tmp_dir = stage_version_dir(object_root, next_n)

          unless dedup
            target = tmp_dir.join('content', logical_path)
            FileUtils.mkdir_p(target.dirname)
            move_or_copy(io, target)
          end

          inv_json = pretty_inventory_json(new_inventory)
          ::File.write(tmp_dir.join(INVENTORY_FILENAME), inv_json)
          ::File.write(tmp_dir.join("#{INVENTORY_FILENAME}#{SIDECAR_SUFFIX}"), sidecar_body(inv_json))

          version_dir = object_root.join(next_v)
          FileUtils.mv(tmp_dir.to_s, version_dir.to_s)

          update_head_pointer(object_root, inv_json)

          physical = object_root.join(new_inventory.content_path_for(digest))
          build_file(key: key, version: next_v, logical_path: logical_path, physical: physical)
        end

        def bootstrap_object!(object_root)
          FileUtils.mkdir_p(object_root)
          namaste = object_root.join('0=ocfl_object_1.1')
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
          FileUtils.mv(tmp_inv.to_s, object_root.join(INVENTORY_FILENAME).to_s)
          FileUtils.mv(tmp_sidecar.to_s, object_root.join("#{INVENTORY_FILENAME}#{SIDECAR_SUFFIX}").to_s)
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
    end
  end
end
