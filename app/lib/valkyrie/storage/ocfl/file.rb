# frozen_string_literal: true

module Valkyrie
  module Storage
    class OCFL
      # Subclass exists so we can attach OCFL-specific behavior in the future.
      # Inherits id, io, version_id, checksum(digests:), valid?(size:, digests:),
      # disk_path (Pathname.new(io.path)), read, stream, rewind, close.
      class File < Valkyrie::StorageAdapter::File
      end
    end
  end
end
