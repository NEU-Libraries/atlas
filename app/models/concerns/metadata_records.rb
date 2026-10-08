# frozen_string_literal: true

# The additional metadata records a Work can hold beside its MODS and METS, one
# concern per format in metadata_records/. See docs/metadata-records.md.
module MetadataRecords
  # Each format's audit `source` and its token in the Work JSON's
  # `metadata_formats`. MODSVersionHistory excludes these from MODS edits,
  # because every record shares the `metadata` change type.
  SOURCES = %w[dwc].freeze
end
