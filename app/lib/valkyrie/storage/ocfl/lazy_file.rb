# frozen_string_literal: true

module Valkyrie
  module Storage
    class OCFL
      # Lifted from Valkyrie::Storage::Disk::LazyFile. Validates path on .open
      # but doesn't keep a real handle until a delegated method is called, so
      # find_by doesn't leak file descriptors.
      class LazyFile
        def self.open(path, mode)
          # Opened and closed in one step purely to raise Errno::ENOENT for a
          # missing path now, rather than when a delegated method first reads.
          ::File.open(path, mode) { nil }
          new(path, mode)
        end

        delegate(*(::File.instance_methods - Object.instance_methods), to: :_inner_file)

        def initialize(path, mode)
          @__path = path
          @__mode = mode
        end

        def _inner_file
          @_inner_file ||= ::File.open(@__path, @__mode)
        end
      end
    end
  end
end
