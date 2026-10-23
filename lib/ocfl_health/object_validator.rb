# frozen_string_literal: true

module OcflHealth
  # Validates one OCFL 1.1 object directory against the spec, plus the two
  # conventions Atlas adds: the inventory id is urn:neu-drs:<key>, and a write
  # stages a version in .tmp-vN-* before renaming it into place.
  class ObjectValidator
    NAMASTE = '0=ocfl_object_1.1'
    NAMASTE_BODY = "ocfl_object_1.1\n"
    INVENTORY = 'inventory.json'
    INVENTORY_TYPE = 'https://ocfl.io/1.1/spec/#inventory'
    DIGESTS = { 'sha512' => Digest::SHA512, 'sha256' => Digest::SHA256 }.freeze
    VERSION = /\Av(\d+)\z/
    ID_NAMESPACE = 'urn:neu-drs'
    ALLOWED_ENTRIES = [NAMASTE, INVENTORY, 'extensions', 'logs'].freeze

    attr_reader :root, :key, :findings, :inventory

    def initialize(root, key: nil, fixity: true)
      @root = Pathname.new(root)
      @key = key || @root.basename.to_s
      @fixity = fixity
      @findings = []
    end

    def call
      return tap { fatal(:not_an_object, 'no object directory') } unless root.directory?

      check_namaste
      @inventory = load_inventory
      return self if inventory.nil?
      return self unless structure_usable?

      check_versions
      check_manifest
      check_version_inventories
      check_root_entries
      self
    end

    def grade
      OcflHealth.grade(findings)
    end

    # The head version's bytes for one logical path, or nil.
    def head_file(logical_path)
      content_for(head_state, logical_path)
    end

    def head_logical_paths
      head_state.values.flatten
    end

    # One logical path's bytes in each version that holds it, oldest first.
    def each_version_of(logical_path)
      return enum_for(:each_version_of, logical_path) unless block_given?

      Hash(inventory&.fetch('versions', nil)).sort_by { |label, _| label[VERSION, 1].to_i }.each do |label, version|
        path = content_for(version['state'], logical_path)
        yield label, path if path&.file?
      end
    end

    private

      def content_for(state, logical_path)
        digest = Hash(state).find { |_digest, paths| Array(paths).include?(logical_path) }&.first
        path = digest && inventory['manifest'].fetch(digest, []).first
        path && root.join(path)
      end

      def head_state
        inventory&.dig('versions', inventory['head'], 'state') || {}
      end

      def add(severity, code, message)
        findings << Finding.new(severity: severity, code: code, message: message, subject: key)
      end

      def fatal(code, message) = add(:fatal, code, message)
      def repairable(code, message) = add(:repairable, code, message)
      def advisory(code, message) = add(:advisory, code, message)

      def check_namaste
        marker = root.join(NAMASTE)
        if !marker.file?
          repairable(:namaste_missing, "#{NAMASTE} is absent")
        elsif marker.read != NAMASTE_BODY
          repairable(:namaste_body, "#{NAMASTE} does not read #{NAMASTE_BODY.inspect}")
        end
      end

      # Atlas reads the highest vN inventory when the head pair is missing or
      # fails its sidecar, so either is recoverable as long as a version holds one.
      def load_inventory
        head = root.join(INVENTORY)
        parsed = parse_json(head) if head.file?
        return parsed.tap { check_sidecar(head, parsed) } if parsed

        load_fallback_inventory(head)
      end

      def load_fallback_inventory(head)
        fallback = highest_version_dir&.join(INVENTORY)
        parsed = parse_json(fallback) if fallback&.file?
        unless parsed
          fatal(:no_inventory, 'no readable inventory at the root or in any version')
          return nil
        end

        repairable(:head_inventory_unreadable, "root #{INVENTORY} is #{head.file? ? 'unparseable' : 'absent'}; " \
                                               "read #{fallback.relative_path_from(root)}")
        parsed
      end

      def parse_json(path)
        JSON.parse(path.read)
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def check_sidecar(inventory_path, parsed)
        algorithm = parsed['digestAlgorithm'] || 'sha512'
        sidecar = Pathname.new("#{inventory_path}.#{algorithm}")
        label = inventory_path.relative_path_from(root)
        return repairable(:sidecar_missing, "#{label} has no .#{algorithm} sidecar") unless sidecar.file?

        recorded = sidecar.read.split(/\s+/).first.to_s.downcase
        actual = DIGESTS.fetch(algorithm, Digest::SHA512).file(inventory_path.to_s).hexdigest
        repairable(:sidecar_mismatch, "#{label} does not match its sidecar") unless recorded == actual
      end

      # Answers false when the inventory is too malformed to check anything else.
      def structure_usable?
        unless inventory['manifest'].is_a?(Hash) && inventory['versions'].is_a?(Hash) &&
               DIGESTS.key?(inventory['digestAlgorithm'])
          fatal(:inventory_malformed, 'inventory lacks a manifest, versions or a supported digestAlgorithm')
          return false
        end

        repairable(:inventory_type, "type is #{inventory['type'].inspect}") unless inventory['type'] == INVENTORY_TYPE
        check_inventory_id
        true
      end

      # An id naming a different key means these bytes were filed under the wrong
      # NOID, and a rebuild would attach them to the wrong resource.
      def check_inventory_id
        expected = "#{ID_NAMESPACE}:#{key}"
        id = inventory['id'].to_s
        return if id == expected

        if id.start_with?("#{ID_NAMESPACE}:")
          fatal(:inventory_names_another_object, "inventory id is #{id}, directory is #{key}")
        else
          advisory(:inventory_id_foreign, "inventory id #{id.inspect} is not #{expected}")
        end
      end

      def check_versions
        labels = inventory['versions'].keys
        numbers = labels.filter_map { |label| label[VERSION, 1]&.to_i }
        if numbers.size < labels.size
          repairable(:version_label, "unrecognised version labels #{labels - labels.grep(VERSION)}")
        end
        check_sequence(labels, numbers)
        inventory['versions'].each { |label, version| check_version(label, version) }
      end

      def check_sequence(labels, numbers)
        unless numbers.sort == (1..numbers.size).to_a
          fatal(:version_sequence, "versions are #{labels.sort.join(', ')}, not v1..v#{numbers.max}")
        end
        return if inventory['head'] == "v#{numbers.max}"

        repairable(:head_not_latest, "head is #{inventory['head']}, latest is v#{numbers.max}")
      end

      def check_version(label, version)
        repairable(:version_directory_missing, "#{label}/ is absent") unless root.join(label).directory?
        begin
          Time.iso8601(version['created'].to_s)
        rescue ArgumentError
          repairable(:version_created, "#{label} created #{version['created'].inspect} is not ISO 8601")
        end

        Hash(version['state']).each do |digest, paths|
          next if inventory['manifest'].key?(digest)

          fatal(:state_digest_unknown, "#{label} names #{Array(paths).join(', ')} by a digest the manifest lacks")
        end
      end

      def check_manifest
        manifested = Set.new
        inventory['manifest'].each do |digest, paths|
          Array(paths).each do |content_path|
            manifested << content_path
            check_content(digest, content_path)
          end
        end
        check_unreferenced_digests
        check_unmanifested_files(manifested)
      end

      def check_content(digest, content_path)
        physical = root.join(content_path)
        return fatal(:content_missing, "#{content_path} is in the manifest but not on disk") unless physical.file?
        return unless @fixity

        actual = DIGESTS.fetch(inventory['digestAlgorithm']).file(physical.to_s).hexdigest
        return if actual == digest.downcase

        fatal(:fixity_mismatch, "#{content_path} no longer matches its recorded digest")
      end

      def check_unreferenced_digests
        referenced = inventory['versions'].values.flat_map { |v| Hash(v['state']).keys }.to_set
        (inventory['manifest'].keys.to_set - referenced).each do |digest|
          repairable(:manifest_unreferenced, "manifest entry #{digest[0, 12]}… is in no version's state")
        end
      end

      def check_unmanifested_files(manifested)
        content_dir = inventory['contentDirectory'] || 'content'
        version_dirs.each do |dir|
          base = dir.join(content_dir)
          next unless base.directory?

          Pathname.glob(base.join('**', '*'), File::FNM_DOTMATCH).each do |path|
            next unless path.file?

            rel = path.relative_path_from(root).to_s
            unless manifested.include?(rel)
              repairable(:unmanifested_content, "#{rel} is on disk but not in the manifest")
            end
          end
        end
      end

      def check_version_inventories
        version_dirs.each do |dir|
          label = dir.basename.to_s
          path = dir.join(INVENTORY)
          next advisory(:version_inventory_missing, "#{label}/#{INVENTORY} is absent") unless path.file?

          parsed = parse_json(path)
          next repairable(:version_inventory_unreadable, "#{label}/#{INVENTORY} is unparseable") unless parsed

          check_sidecar(path, parsed)
          compare_version_inventory(label, path, parsed)
        end
      end

      # The root inventory must be byte-identical to the head version's. Atlas
      # writes the two in separate renames, so a crash between them leaves
      # exactly this, and copying the version's inventory up repairs it.
      def compare_version_inventory(label, path, parsed)
        if label == inventory['head']
          head = root.join(INVENTORY)
          if head.file? && head.read != path.read
            repairable(:head_inventory_mismatch, "root #{INVENTORY} differs from #{label}/#{INVENTORY}")
          end
          return
        end

        Hash(parsed['versions']).each do |older, record|
          next if inventory.dig('versions', older) == record

          repairable(:version_history_diverges, "#{label}/#{INVENTORY} records #{older} differently from the root")
        end
      end

      def check_root_entries
        root.children.each do |child|
          name = child.basename.to_s
          next if ALLOWED_ENTRIES.include?(name) || name.start_with?("#{INVENTORY}.")
          next if child.directory? && name.match?(VERSION) && inventory['versions'].key?(name)

          classify_root_entry(name, child)
        end
      end

      def classify_root_entry(name, child)
        if name.start_with?('.tmp-v')
          repairable(:staging_residue, "#{name}/ is a version that was staged and never committed")
        elsif name.start_with?('tmp_inventory.json')
          repairable(:head_swap_residue, "#{name} is left from an interrupted head-inventory swap")
        elsif child.directory? && name.match?(VERSION)
          repairable(:version_not_in_inventory, "#{name}/ is on disk but not in the inventory")
        else
          repairable(:unexpected_entry, "#{name} does not belong in an object root")
        end
      end

      def version_dirs
        root.children.select { |c| c.directory? && c.basename.to_s.match?(VERSION) }
            .sort_by { |c| c.basename.to_s[VERSION, 1].to_i }
      end

      def highest_version_dir
        version_dirs.last
      end
  end
end
