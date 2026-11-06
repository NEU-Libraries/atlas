# frozen_string_literal: true

# Rolls a Work's download access up onto its own Solr doc, so a results page
# can decide whether to offer downloads without an Atlas read per row. See
# docs/solr-indexing.md.
#
#   has_downloads_bsi          <- whether GET /works/:id/assets lists anything
#   download_read_groups_ssim  <- the union of every listed asset's read gate
class DownloadAccessIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    assets = DownloadableAssetsQuery.call(work: resource).map(&:first)
    {
      has_downloads_bsi:         assets.any?,
      download_read_groups_ssim: assets.flat_map { |asset| resource.derivative_gate_for(asset) }.uniq
    }
  end
end
