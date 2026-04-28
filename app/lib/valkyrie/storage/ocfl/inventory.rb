# frozen_string_literal: true

module Valkyrie
  module Storage
    class OCFL
      # OCFL 1.1 inventory.json value object — pure Ruby, no I/O.
      #
      # Distinction the upstream spec is strict about:
      #   manifest[digest] -> array of CONTENT paths   (e.g. "v1/content/foo.jpg")
      #   versions[vN][state][digest] -> array of LOGICAL paths (e.g. "foo.jpg")
      class Inventory
        TYPE = 'https://ocfl.io/1.1/spec/#inventory'
        DEFAULT_CONTENT_DIRECTORY = 'content'

        attr_reader :id, :digest_algorithm, :head, :content_directory, :manifest, :versions

        def initialize(id:,
                       digest_algorithm: 'sha512',
                       head: 'v0',
                       content_directory: DEFAULT_CONTENT_DIRECTORY,
                       manifest: {},
                       versions: {})
          @id = id
          @digest_algorithm = digest_algorithm
          @head = head
          @content_directory = content_directory
          @manifest = manifest
          @versions = versions
        end

        def self.empty(id:, digest_algorithm: 'sha512')
          new(id: id, digest_algorithm: digest_algorithm)
        end

        def self.from_h(hash)
          new(
            id: hash.fetch('id'),
            digest_algorithm: hash.fetch('digestAlgorithm', 'sha512'),
            head: hash.fetch('head'),
            content_directory: hash.fetch('contentDirectory', DEFAULT_CONTENT_DIRECTORY),
            manifest: hash.fetch('manifest', {}),
            versions: hash.fetch('versions', {})
          )
        end

        def self.parse(json_string)
          from_h(JSON.parse(json_string))
        end

        def head_int
          head == 'v0' ? 0 : head.delete_prefix('v').to_i
        end

        def empty?
          head == 'v0'
        end

        def to_h
          {
            'id' => id,
            'type' => TYPE,
            'digestAlgorithm' => digest_algorithm,
            'head' => head,
            'contentDirectory' => content_directory,
            'manifest' => manifest,
            'versions' => versions
          }
        end

        def to_json(*_args)
          JSON.pretty_generate(to_h)
        end

        # Returns the content path stored in the manifest for the given digest,
        # or nil.
        def content_path_for(digest)
          manifest[digest]&.first
        end

        # Returns the digest of a logical path within a specific version, or nil.
        def digest_for(version:, logical_path:)
          state = versions.dig(version, 'state') || {}
          state.each do |digest, paths|
            return digest if paths.include?(logical_path)
          end
          nil
        end

        # Returns the head version's full state hash (digest => [logical_paths]).
        def head_state
          versions.dig(head, 'state') || {}
        end

        def dedup?(digest)
          manifest.key?(digest)
        end

        # Returns version names that contain a given logical path, sorted newest
        # first by numeric vN.
        def versions_containing(logical_path)
          containing = versions.select do |_v, vdata|
            (vdata['state'] || {}).values.flatten.include?(logical_path)
          end
          containing.keys.sort_by { |v| v.delete_prefix('v').to_i }.reverse
        end

        # Returns a new Inventory with vN+1 appended for the given digest /
        # logical_path / content_path triple. Manifest dedups when the digest
        # is already present. State clones from head, removing any prior
        # binding for the logical_path, then asserts the new digest -> path.
        def bump(digest:, logical_path:, content_path:, created:, message:, user:)
          next_n = head_int + 1
          next_v = "v#{next_n}"

          new_manifest = deep_dup_manifest
          new_manifest[digest] = [content_path] unless new_manifest.key?(digest)

          new_state = state_replacing_logical(head_state, digest, logical_path)

          new_versions = versions.merge(
            next_v => {
              'created' => created,
              'message' => message,
              'user' => user,
              'state' => new_state
            }
          )

          self.class.new(
            id: id,
            digest_algorithm: digest_algorithm,
            head: next_v,
            content_directory: content_directory,
            manifest: new_manifest,
            versions: new_versions
          )
        end

        private

          def deep_dup_manifest
            manifest.transform_values(&:dup)
          end

          # Clone state, drop logical_path from any existing bucket, ensure
          # logical_path appears under digest exactly once.
          def state_replacing_logical(state, digest, logical_path)
            result = {}
            state.each do |d, paths|
              remaining = paths - [logical_path]
              result[d] = remaining unless remaining.empty?
            end
            existing = result[digest] || []
            result[digest] = (existing + [logical_path]).uniq
            result
          end
      end
    end
  end
end
