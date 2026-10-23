# frozen_string_literal: true

module OcflHealth
  # Can this Work be reconstituted from disk alone? Walks the Work's graph as
  # the envelopes record it and validates every object it reaches, fixity
  # included. Postgres may hold more; this answers only for what disk holds.
  class WorkAssessment
    MODS_FILENAME = 'descMetadata.xml'
    DESCRIPTIVE = 'Descriptive Metadata'
    METADATA_CLASSIFICATIONS = ['Descriptive Metadata', 'Structural Metadata', 'Darwin Core'].freeze
    ENVELOPE_FILES = (Envelope::GRAPH_FILES + [Envelope::PERMISSIONS_FILE]).freeze
    PARENT_TYPES = { 'Work' => %w[Collection], 'Collection' => %w[Collection Community],
                     'Community' => %w[Community] }.freeze

    attr_reader :noid, :findings, :facts

    def initialize(pool, noid, fixity: true)
      @pool = pool
      @noid = noid
      @fixity = fixity
      @findings = []
      @facts = { objects: 0 }
    end

    def call
      envelope = validate(noid, expect: 'Work')
      return self if envelope.nil?

      record_work_facts(envelope)
      assess_ancestry(envelope)
      assess_file_sets
      self
    end

    def grade
      OcflHealth.grade(findings)
    end

    def to_h
      { noid: noid, grade: grade, facts: facts, findings: findings.map(&:to_h) }
    end

    private

      def add(severity, code, message, subject = noid)
        findings << Finding.new(severity: severity, code: code, message: message, subject: subject)
      end

      # Full validation of one object, findings merged in. Answers its envelope,
      # or nil when the object is absent or is not the type the graph says.
      def validate(key, expect:)
        path = @pool.object_path(key)
        if path.nil?
          add(:fatal, :"#{expect.downcase}_missing", "#{expect} #{key} has no object on disk", key)
          return nil
        end

        validator = ObjectValidator.new(path, key: key, fixity: @fixity).call
        envelope = Envelope.read(validator)
        @facts[:objects] += 1
        findings.concat(validator.findings, envelope.findings)
        @validators ||= {}
        @validators[key] = validator
        return envelope if envelope.type.nil? || envelope.type == expect

        add(:fatal, :wrong_type, "#{key} is a #{envelope.type}, expected a #{expect}", key)
        nil
      end

      def record_work_facts(envelope)
        perms = envelope.permissions || {}
        @facts.merge!(handle: envelope.graph&.fetch('handle', nil), depositor: perms['depositor'],
                      read: perms['read'], tombstoned: !envelope.graph&.fetch('tombstone', nil).nil?)
        add(:advisory, :withdrawn, 'the envelope records a withdrawal') if @facts[:tombstoned]
        add(:advisory, :no_handle, 'no handle in the envelope') if @facts[:handle].nil?
      end

      # A missing parent loses placement, not content: the Work can be re-filed.
      def assess_ancestry(envelope)
        chain = []
        current = envelope
        while (entry = parent_entry(current, chain))
          check_parent(current, entry.envelope)
          chain << entry.key
          current = entry.envelope
        end
        @facts[:ancestors] = chain.reverse
      end

      # The next object up, or nil at the top or where the chain breaks.
      def parent_entry(current, chain)
        parent = current.parents.first
        if parent.nil?
          add(:repairable, :no_parent, "#{current.key} names no parent") unless current.type == 'Community'
        elsif chain.include?(parent)
          add(:repairable, :ancestry_cycle, "#{parent} reappears in the ancestry")
        elsif (entry = @pool.index[parent]).nil?
          add(:repairable, :parent_missing, "parent #{parent} of #{current.key} is not on disk")
        else
          return entry
        end
        nil
      end

      def check_parent(child, parent)
        allowed = PARENT_TYPES.fetch(child.type.to_s, [])
        unless allowed.include?(parent.type)
          add(:repairable, :wrong_parent_type, "#{child.key} is a #{child.type} filed under #{parent.type} #{parent.key}")
        end
        return if @facts[:tombstoned] || parent.graph&.fetch('tombstone', nil).nil?

        add(:repairable, :live_under_withdrawn, "the Work is live but ancestor #{parent.key} is withdrawn")
      end

      def assess_file_sets
        file_sets = @pool.children_of(noid).select { |entry| entry.envelope.type == 'FileSet' }
        descriptive, others = file_sets.partition { |fs| classification(fs) == DESCRIPTIVE }
        content = others.select { |fs| content?(fs) }
        @facts[:file_sets] = file_sets.size
        @facts[:content_file_sets] = content.size

        assess_descriptive(descriptive)
        add(:advisory, :no_content_files, 'no content FileSet on disk') if content.empty?
        others.each { |fs| assess_members(fs) }
      end

      def classification(entry)
        entry.envelope.graph&.fetch('classification', nil)
      end

      def content?(entry)
        METADATA_CLASSIFICATIONS.none?(classification(entry))
      end

      def assess_descriptive(file_sets)
        return add(:fatal, :mods_missing, 'no descriptive-metadata FileSet on disk') if file_sets.empty?

        if file_sets.size > 1
          add(:repairable, :duplicate_descriptive_file_sets, "#{file_sets.size} descriptive FileSets")
        end
        blobs = file_sets.flat_map { |fs| assess_members(fs) }
        mods = blobs.find { |key, envelope| mods_blob?(key, envelope) }
        return add(:fatal, :mods_missing, 'no descriptive-metadata Blob on disk') if mods.nil?

        assess_mods(@validators[mods.first])
      end

      def mods_blob?(key, envelope)
        envelope.graph&.fetch('use', nil) == DESCRIPTIVE && @validators.key?(key)
      end

      # Answers [key, envelope] for each member Blob that resolved.
      def assess_members(file_set)
        envelope = validate(file_set.key, expect: 'FileSet')
        return [] if envelope.nil?

        check_dropped_members(file_set.key, envelope)
        if envelope.members.empty? && content?(file_set)
          add(:repairable, :empty_file_set, "content FileSet #{file_set.key} holds no Blob", file_set.key)
        end
        envelope.members.filter_map do |key|
          blob = validate(key, expect: 'Blob')
          next if blob.nil?

          check_blob_bytes(key)
          [key, blob]
        end
      end

      # The envelope is rewritten from Postgres, so a broken link there reaches
      # disk on the next write. OCFL keeps every version, and an earlier one
      # still naming the lost Blob is the evidence a repair needs.
      def check_dropped_members(key, envelope)
        named = Set.new
        @validators[key].each_version_of('relationships.json') do |_label, path|
          named.merge(Array(JSON.parse(path.read)['member_ids']))
        rescue JSON::ParserError
          next
        end
        dropped = named.to_a - envelope.members
        return if dropped.empty?

        add(:advisory, :members_dropped, "an earlier version named #{dropped.join(', ')}; the head does not", key)
      end

      def check_blob_bytes(key)
        payload = @validators[key].head_logical_paths - ENVELOPE_FILES
        add(:fatal, :blob_without_bytes, "Blob #{key} holds no file besides its envelope", key) if payload.empty?
      end

      def assess_mods(validator)
        path = validator.head_file(MODS_FILENAME)
        unless path&.file?
          return add(:fatal, :mods_missing, "#{MODS_FILENAME} is not in the head version", validator.key)
        end

        mods = ModsReading.read(path)
        if mods.error
          return add(:fatal, :mods_unparseable, "#{MODS_FILENAME} is not well-formed XML: #{mods.error}",
                     validator.key)
        end

        @facts[:title] = mods.title
        add(:repairable, :mods_untitled, 'the MODS has no title', validator.key) if mods.title.nil?
        add(:advisory, :mods_no_keywords, 'the MODS has no subject', validator.key) if mods.subjects.zero?
      end
  end
end
