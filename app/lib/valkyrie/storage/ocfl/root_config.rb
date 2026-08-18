# frozen_string_literal: true

# Builds the name => path map an OCFL adapter is configured with.
#
# The roster has to vary by environment while the initializer is shared. Dev,
# staging and production each mount their own storage, and a configured root
# whose path is not a real mount becomes container-local storage that vanishes on
# restart — silently, because the adapter creates a root it does not find. So
# extra roots arrive from the environment, and an environment that has
# provisioned none keeps exactly one.
module Valkyrie
  module Storage
    class OCFL
      class RootConfig
        ENV_VAR = 'OCFL_EXTRA_ROOTS'

        def self.roots(primary_name:, primary_path:, extra: ENV.fetch(ENV_VAR, ''))
          new(primary_name: primary_name, primary_path: primary_path, extra: extra).roots
        end

        def initialize(primary_name:, primary_path:, extra:)
          @primary_name = primary_name.to_s
          @primary_path = primary_path
          @extra = extra.to_s
        end

        # Primary first, because the first unsealed root is the one new objects land
        # in and the primary is the one that already holds content.
        def roots
          parsed.each_key do |name|
            raise ArgumentError, "#{ENV_VAR} cannot redefine the primary root #{name.inspect}" if name == primary_name
          end

          { primary_name => primary_path }.merge(parsed)
        end

        private

          attr_reader :primary_name, :primary_path, :extra

          # "r002=/mnt/two,r003=/mnt/three". A malformed entry raises rather than being
          # skipped: a root missing from the pool is a root whose objects cannot be
          # found, which reads as data loss.
          def parsed
            @parsed ||= extra.split(',').map(&:strip).reject(&:empty?).to_h do |pair|
              name, path = pair.split('=', 2)
              raise ArgumentError, "#{ENV_VAR} needs name=path entries, got #{pair.inspect}" if path.blank?

              [name.strip, Pathname.new(path.strip)]
            end
          end
      end
    end
  end
end
