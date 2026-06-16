# frozen_string_literal: true

module FileHelper
  # Allowlist of digest algorithms accepted on the verify-on-ingest path.
  # OCFL records sha512, but a v1 migration manifest may carry the expected
  # checksum in another algorithm — verification hashes in whatever the
  # caller names, independent of OCFL's storage digest.
  DIGEST_CLASSES = {
    'sha512' => Digest::SHA512,
    'sha256' => Digest::SHA256,
    'sha1'   => Digest::SHA1,
    'md5'    => Digest::MD5
  }.freeze

  DIGEST_CHUNK = 65_536

  # Streams the file at file_path into the storage adapter. The File handle is
  # opened in a block so it closes deterministically — across a TB migration of
  # millions of files an undeterministically-closed handle risks FD exhaustion.
  #
  # Memory: this never buffers the whole file. Rack disk-spools the multipart
  # part to a Tempfile, the OCFL adapter does a zero-copy `mv` (or a chunked
  # IO.copy_stream when it can't move) and hashes in fixed chunks — so a
  # multi-GB upload lands with flat, bounded memory. (The client-side Faraday
  # request-body streaming guarantee lives in atlas_rb, a separate repo.)
  def create_file(file_path, resource, original_filename = file_path.split('/').last)
    File.open(file_path) do |io| # tei, png, txt
      Valkyrie.config.storage_adapter.upload(
        file:              io,
        resource:          resource, # Blob
        original_filename: original_filename
      )
    end
  end

  # The fixity digest the storage layer recorded for a stored revision, as a
  # self-describing "<algorithm>:<hexvalue>" string (e.g. "sha512:abc…"), read
  # from the OCFL inventory without re-hashing the bytes. nil if the id doesn't
  # resolve or the adapter doesn't record digests.
  def recorded_digest(id)
    adapter = Valkyrie.config.storage_adapter
    return nil unless adapter.respond_to?(:digest_for)

    recorded = adapter.digest_for(id: id)
    recorded && "#{recorded[:algorithm]}:#{recorded[:value]}"
  end

  # Verify-on-ingest: hash the file at `path` and confirm it matches the
  # caller-supplied `expected_digest` ("<algorithm>:<hexvalue>"). No-op when
  # expected_digest is blank. Streams in fixed chunks (bounded memory). Raises
  # Exceptions::FixityMismatch on an unsupported algorithm or a value mismatch
  # so the caller can reject a corrupted transfer *before* persisting anything.
  def verify_digest!(path, expected_digest)
    return if expected_digest.blank?

    algorithm, digest_class, expected = parse_expected_digest(expected_digest)
    actual = stream_digest(path, digest_class)
    return if actual.casecmp?(expected)

    raise Exceptions::FixityMismatch.new(
      :fixity_mismatch,
      "uploaded bytes do not match expected #{algorithm} digest " \
      "(expected #{expected}, got #{actual})"
    )
  end

  private

    # Splits "<algorithm>:<hexvalue>" into [algorithm, digest_class, expected],
    # raising FixityMismatch(:unsupported_digest_algorithm) on a bad shape or an
    # algorithm outside the allowlist.
    def parse_expected_digest(expected_digest)
      algorithm, expected = expected_digest.to_s.split(':', 2)
      algorithm = algorithm.to_s.downcase
      digest_class = DIGEST_CLASSES[algorithm]
      if digest_class.nil? || expected.blank?
        raise Exceptions::FixityMismatch.new(
          :unsupported_digest_algorithm,
          'expected_digest must be "<algorithm>:<hexvalue>" with one of ' \
          "#{DIGEST_CLASSES.keys.join(', ')}; got #{expected_digest.inspect}"
        )
      end

      [algorithm, digest_class, expected]
    end

    def stream_digest(path, digest_class)
      digest = digest_class.new
      File.open(path, 'rb') do |io|
        while (chunk = io.read(DIGEST_CHUNK))
          digest.update(chunk)
        end
      end
      digest.hexdigest
    end
end
