# frozen_string_literal: true

# A memory-safe Rack response body for a single byte range of a file. Mirrors
# ActionDispatch::Http::FileBody, but seeks to an offset and stops after
# `length` bytes, so a `206 Partial Content` response streams only the
# requested slice and never buffers the whole file. Deliberately does NOT
# expose `#to_path`: that would let Rack::Sendfile hand the *entire* file to
# the front server and bypass the range. Used by BlobsController#content for
# seekable A/V playback.
class FileSlice
  CHUNK = 16_384

  def initialize(path, offset, length)
    @path   = path
    @offset = offset
    @length = length
  end

  def each
    ::File.open(@path, 'rb') do |file|
      file.seek(@offset)
      remaining = @length
      while remaining.positive? && (chunk = file.read([CHUNK, remaining].min))
        remaining -= chunk.bytesize
        yield chunk
      end
    end
  end
end
