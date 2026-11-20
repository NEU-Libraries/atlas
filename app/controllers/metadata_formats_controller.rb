# frozen_string_literal: true

# The metadata formats Atlas previews, so a client builds its format list from
# Atlas rather than its own copy. See docs/metadata-records.md.
class MetadataFormatsController < ApplicationController
  def index
    authorize! :read, :metadata_formats

    @formats = MetadataRecords.previewable
  end
end
