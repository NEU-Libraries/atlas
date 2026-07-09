# frozen_string_literal: true

# MIME detection for deposited binaries, backed by Marcel. Marcel vendors
# Apache Tika's magic database inside the gem, so detection is pinned by
# Gemfile.lock rather than varying with the OS's libmagic version — the
# detected mime_type lands in METS and preservation envelopes, so
# reproducibility across environments matters.
module MimeHelper
  # Exact mime → classification overrides. application/* types can't be
  # derived from the media type at all. The enumerated text/* subtypes
  # (csv, xml, tab-separated-values) would otherwise fall through the
  # media-type table as plain :text, so they're pinned to :structured_text
  # here — text-encoded but structured/machine-readable, distinct from prose.
  # Anything unlisted falls through to CLASSIFICATION_BY_MEDIA_TYPE, then
  # Classification.generic.
  CLASSIFICATION_BY_MIME_TYPE = {
    'application/msword'                                                        => :text,
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'   => :text,
    'application/pdf'                                                           => :text,
    'application/epub+zip'                                                      => :text,
    'application/xml'                                                           => :structured_text,
    'text/xml'                                                                  => :structured_text,
    'application/json'                                                          => :structured_text,
    'text/csv'                                                                  => :structured_text,
    'text/tab-separated-values'                                                 => :structured_text,
    'application/vnd.ms-excel'                                                  => :spreadsheet,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'         => :spreadsheet,
    'application/vnd.ms-powerpoint'                                             => :presentation,
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' => :presentation,
    'application/vnd.openxmlformats-officedocument.presentationml.slideshow'    => :presentation,
    'application/zip'                                                           => :archive,
    'application/x-tar'                                                         => :archive
  }.freeze

  CLASSIFICATION_BY_MEDIA_TYPE = {
    'image' => :image,
    'video' => :video,
    'audio' => :audio,
    'text'  => :text
  }.freeze

  LABEL_BY_EXT = {
    'doc' => :msword, 'docx' => :msword,
    'xls' => :msexcel, 'xlsx' => :msexcel, 'xlw' => :msexcel,
    'ppt' => :mspowerpoint, 'pptx' => :mspowerpoint, 'pps' => :mspowerpoint, 'ppsx' => :mspowerpoint,
    'pdf' => :pdf,
    'epub' => :epub,
    'xml' => :structured_text, 'json' => :structured_text, 'csv' => :structured_text, 'tsv' => :structured_text,
    'zip' => :zip, 'tar' => :zip
  }.freeze

  # The name hint disambiguates formats with weak or absent magic bytes
  # (CSV, legacy Office). Uploads arrive as Rack tempfiles, so callers
  # should pass the user-supplied original filename when they have one;
  # the path's basename is only a fallback.
  def mime_type(file_path, name: nil)
    Marcel::MimeType.for(Pathname.new(file_path), name: name.presence || File.basename(file_path))
  end

  def assign_classification(file_path, name: nil)
    type = mime_type(file_path, name: name)
    key = CLASSIFICATION_BY_MIME_TYPE[type] || CLASSIFICATION_BY_MEDIA_TYPE[type.split('/').first]
    key ? Classification.public_send(key) : Classification.generic
  end

  def default_label(file_path, name: nil)
    ext = File.extname(name.presence || file_path).delete_prefix('.').downcase

    label = ext_label(ext)
    return label if label.present?

    classification_label(assign_classification(file_path, name: name))
  end

  private

    def ext_label(ext)
      key = LABEL_BY_EXT[ext]
      key && Label.public_send(key)
    end

    def classification_label(classification)
      case classification
      when Classification.image then Label.image_master
      when Classification.video then Label.video
      when Classification.audio then Label.audio
      when Classification.text then Label.text
      when Classification.structured_text then Label.structured_text
      end
    end
end
