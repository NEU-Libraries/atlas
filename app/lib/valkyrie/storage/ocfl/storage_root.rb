# frozen_string_literal: true

module Valkyrie
  module Storage
    class OCFL
      # OCFL 1.1 storage root: NAMASTE marker, ocfl_layout.json, and the
      # 0007 N-Tuple Omit Prefix layout extension config. Knows how to map a
      # key to its object root path.
      class StorageRoot
        NAMASTE = '0=ocfl_1.1'
        NAMASTE_BODY = "ocfl_1.1\n"
        LAYOUT_EXTENSION = '0007-n-tuple-omit-prefix-storage-layout'

        attr_reader :base_path, :tuple_size, :number_of_tuples

        def initialize(base_path:, tuple_sizes: [2, 2])
          @base_path = Pathname.new(base_path)
          @tuple_size = tuple_sizes.first
          @number_of_tuples = tuple_sizes.size
        end

        # Idempotent. Writes NAMASTE, ocfl_layout.json, and extension config
        # if absent.
        def bootstrap!
          FileUtils.mkdir_p(base_path)

          namaste = base_path.join(NAMASTE)
          ::File.write(namaste, NAMASTE_BODY) unless namaste.exist?

          layout = base_path.join('ocfl_layout.json')
          unless layout.exist?
            ::File.write(layout, JSON.pretty_generate(
                                   'extension'   => LAYOUT_EXTENSION,
                                   'description' => 'Tuple-based layout, key used directly without rehashing.'
                                 ))
          end

          ext_dir = base_path.join('extensions', LAYOUT_EXTENSION)
          ext_config = ext_dir.join('config.json')
          return if ext_config.exist?

          FileUtils.mkdir_p(ext_dir)
          ::File.write(ext_config, JSON.pretty_generate(
                                     'extensionName'  => LAYOUT_EXTENSION,
                                     'tupleSize'      => tuple_size,
                                     'numberOfTuples' => number_of_tuples
                                   ))
        end

        def object_root_for(key)
          base_path.join(*tuples_for(key), key)
        end

        def tuples_for(key)
          pos = 0
          Array.new(number_of_tuples) do
            tuple = key[pos, tuple_size].to_s
            tuple = tuple.ljust(tuple_size, '0') if tuple.length < tuple_size
            pos += tuple_size
            tuple
          end
        end
      end
    end
  end
end
