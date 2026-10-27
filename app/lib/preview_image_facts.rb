# frozen_string_literal: true

# Reads and checks the optional size and placeholder that describe the preview
# image in a `PATCH /resources/:id/thumbnails` body. A blank value is absent.
# Raises Exceptions::PreviewImageError, so a bad body writes nothing.
class PreviewImageFacts
  KEYS = %w[preview_width preview_height preview_placeholder].freeze

  # Generous for a ~16px-wide JPEG (about 900 characters), and small enough
  # that the field cannot hold a real image.
  PLACEHOLDER_LIMIT = 2048

  JPEG_MAGIC = "\xFF\xD8\xFF".b.freeze

  def self.from(source)
    new(source).facts
  end

  def initialize(source)
    @source = source
  end

  # The Delegate attributes for the preview write. Every key is present, so a
  # preview written without them clears the stored ones: a regenerated image
  # can keep its URI and change its size.
  def facts
    facts = { width:       dimension('preview_width'),
              height:      dimension('preview_height'),
              placeholder: placeholder }
    check_pairing!(facts)
    facts
  end

  private

    def check_pairing!(facts)
      if @source['preview'].blank? && facts.values.any?
        raise Exceptions::PreviewImageError.new(:preview_required,
                                                "#{KEYS.join(', ')} describe the preview and need its URI")
      end
      return if facts[:width].nil? == facts[:height].nil?

      raise Exceptions::PreviewImageError.new(:preview_dimensions_incomplete,
                                              'preview_width and preview_height must be sent together')
    end

    def dimension(key)
      value = @source[key]
      return nil if value.blank?

      parsed = Integer(value.to_s, 10)
      return parsed if parsed.positive?

      raise ArgumentError
    rescue ArgumentError
      raise Exceptions::PreviewImageError.new(:invalid_preview_dimension, "#{key} must be a positive integer")
    end

    def placeholder
      value = @source['preview_placeholder']
      return nil if value.blank?
      return value if value.is_a?(String) && value.length <= PLACEHOLDER_LIMIT && jpeg?(value)

      raise Exceptions::PreviewImageError.new(
        :invalid_preview_placeholder,
        "preview_placeholder must be base64 of a JPEG, at most #{PLACEHOLDER_LIMIT} characters"
      )
    end

    def jpeg?(value)
      Base64.strict_decode64(value).start_with?(JPEG_MAGIC)
    rescue ArgumentError
      false
    end
end
