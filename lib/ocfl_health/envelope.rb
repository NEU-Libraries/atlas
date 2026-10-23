# frozen_string_literal: true

module OcflHealth
  # The preservation envelope Atlas writes into every resource's own object:
  # relationships.json (properties.json for a Blob) and permissions.json. It is
  # what lets disk alone place an object in the graph, so a missing envelope is
  # repairable only while Postgres still holds the record.
  class Envelope
    # Mirrors Preservable::ENVELOPE_SCHEMA_VERSION; a spec keeps the two equal.
    SCHEMA_VERSION = 7
    GRAPH_FILES = %w[relationships.json properties.json].freeze
    PERMISSIONS_FILE = 'permissions.json'

    attr_reader :key, :graph, :permissions, :findings

    def self.read(validator)
      new(validator).tap(&:call)
    end

    def initialize(validator)
      @validator = validator
      @key = validator.key
      @findings = []
    end

    def call
      return if @validator.inventory.nil?

      @graph = read_graph
      @permissions = read_json(PERMISSIONS_FILE)
      return if @graph.nil?

      check_identity(@graph, 'graph')
      check_identity(@permissions, PERMISSIONS_FILE) if @permissions
      return repairable(:permissions_missing, "no #{PERMISSIONS_FILE} in the head version") if @permissions.nil?

      check_schema
    end

    def type
      graph&.fetch('type', nil)
    end

    def parents
      Array(graph&.fetch('a_member_of', nil))
    end

    def members
      Array(graph&.fetch('member_ids', nil))
    end

    private

      def repairable(code, message)
        findings << Finding.new(severity: :repairable, code: code, message: message, subject: key)
      end

      def read_graph
        name = GRAPH_FILES.find { |file| @validator.head_logical_paths.include?(file) }
        return read_json(name) if name

        repairable(:envelope_missing, 'no relationships.json or properties.json in the head version')
        nil
      end

      def read_json(name)
        path = @validator.head_file(name)
        return nil unless path&.file?

        JSON.parse(path.read)
      rescue JSON::ParserError
        repairable(:envelope_unparseable, "#{name} is not JSON")
        nil
      end

      def check_identity(payload, label)
        return if payload['noid'] == key

        findings << Finding.new(severity: :fatal, code: :envelope_names_another_object,
                                message: "#{label} names #{payload['noid'].inspect}", subject: key)
      end

      def check_schema
        version = graph['schema_version'].to_i
        return if version >= SCHEMA_VERSION

        findings << Finding.new(severity: :advisory, code: :envelope_schema_behind,
                                message: "envelope schema v#{version}, current is v#{SCHEMA_VERSION}", subject: key)
      end
  end
end
