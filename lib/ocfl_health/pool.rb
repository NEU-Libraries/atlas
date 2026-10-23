# frozen_string_literal: true

module OcflHealth
  # One or more OCFL storage roots read as one pool, as Atlas spans them. Finds
  # an object by key and indexes every envelope, because a Work's FileSets name
  # the Work and the Work does not name them: the only way to find a Work's
  # children on disk is to read every object's relationships.json.
  class Pool
    ROOT_NAMASTE = '0=ocfl_1.1'
    LAYOUT_EXTENSION = '0007-n-tuple-omit-prefix-storage-layout'

    Entry = Struct.new(:key, :path, :root, :envelope, keyword_init: true)

    attr_reader :roots, :findings

    def initialize(paths)
      @roots = paths.map { |path| Pathname.new(path) }
      @findings = []
      @roots.each { |root| check_root(root) }
    end

    # Every object directory in the pool. A key held by two roots is a failed
    # migration; both are yielded and the pool records the conflict.
    def each_object(&)
      return enum_for(:each_object) unless block_given?

      roots.each do |root|
        depth = layout(root).fetch('numberOfTuples', 2)
        Dir.glob(root.join(*Array.new(depth, '*'), '*', ObjectValidator::NAMASTE).to_s).each do |marker|
          dir = Pathname.new(marker).dirname
          yield dir.basename.to_s, dir, root
        end
      end
    end

    # The object directory for a key, or nil. Computed from the layout, so a
    # misfiled object reads as absent rather than being found by search.
    def object_path(key)
      holding = roots.filter_map do |root|
        path = path_for(root, key)
        path if path.directory?
      end
      if holding.size > 1
        findings << Finding.new(severity: :fatal, code: :object_in_two_roots, subject: key,
                                message: "held by #{holding.join(' and ')}")
      end
      holding.first
    end

    # Envelopes only, with no fixity: building the graph must stay cheap, and
    # the objects that matter are re-validated in full by whoever asks.
    def index
      @index ||= each_object.to_h do |key, path, root|
        validator = ObjectValidator.new(path, key: key, fixity: false).call
        [key, Entry.new(key: key, path: path, root: root, envelope: Envelope.read(validator))]
      end
    end

    def children_of(key)
      index.values.select { |entry| entry.envelope.parents.include?(key) }
    end

    private

      def check_root(root)
        unless root.join(ROOT_NAMASTE).file?
          findings << Finding.new(severity: :fatal, code: :not_a_storage_root, subject: root.to_s,
                                  message: "#{ROOT_NAMASTE} is absent: unmounted, or not a storage root")
        end
        return if root.join('ocfl_layout.json').file?

        findings << Finding.new(severity: :repairable, code: :layout_missing, subject: root.to_s,
                                message: 'ocfl_layout.json is absent; assuming 2x2 tuples')
      end

      def layout(root)
        @layouts ||= {}
        @layouts[root] ||= begin
          JSON.parse(root.join('extensions', LAYOUT_EXTENSION, 'config.json').read)
        rescue Errno::ENOENT, JSON::ParserError
          { 'tupleSize' => 2, 'numberOfTuples' => 2 }
        end
      end

      # Atlas pads a short key on the right with '0'. Extension 0007 defaults to
      # left padding, but no NOID is shorter than the tuples, so they agree.
      def path_for(root, key)
        size = layout(root).fetch('tupleSize', 2)
        tuples = Array.new(layout(root).fetch('numberOfTuples', 2)) do |i|
          key[i * size, size].to_s.ljust(size, '0')
        end
        root.join(*tuples, key)
      end
  end
end
