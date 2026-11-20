# frozen_string_literal: true

# The additional metadata records a Work can hold beside its MODS and METS, one
# concern per format in metadata_records/. See docs/metadata-records.md.
module MetadataRecords
  # `preview` names the Work method that loads an unsaved access copy from a
  # draft, and `template` the HTML view that renders it.
  Format = Data.define(:token, :label, :media_type, :preview, :template)

  MODS = Format.new(token: 'mods', label: 'MODS', media_type: 'application/xml',
                    preview: :preview_mods, template: 'resources/preview')

  # The additional formats, in the order a client lists them.
  FORMATS = [
    Format.new(token: 'dwc', label: 'Darwin Core', media_type: 'application/xml',
               preview: :preview_darwin_core, template: 'darwin_core/show')
  ].freeze

  # Each format's audit `source` and its token in the Work JSON's
  # `metadata_formats`. MODSVersionHistory excludes these from MODS edits,
  # because every record shares the `metadata` change type.
  SOURCES = FORMATS.map(&:token).freeze

  # Every format POST /resources/preview renders, MODS first.
  def self.previewable
    [MODS, *FORMATS]
  end

  def self.find(token)
    previewable.find { |format| format.token == token.to_s }
  end
end
