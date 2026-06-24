# frozen_string_literal: true

# Projects a Work's derived full-document text onto its own Solr doc as
# `all_text_timv`, so Cerberus's catalog can match body-text queries and render
# the "Full Text Match" result snippet.
#
# The text is extracted Cerberus-side (pdftotext / Tika in a Solid Queue job)
# and handed to Atlas via PATCH /works/:id/full_text, which stores it as the
# Work's derived `full_text` attribute. This indexer is the storage→Solr half:
# it re-reads that stored value on every Work save, so the projection survives
# reset:data / reindex (Atlas is the source of truth; Cerberus never writes Solr
# directly). Mirrors ClassificationIndexer / ThumbnailIndexer's "project a
# stored value onto the Work doc" pattern; Atlas and Cerberus share one Solr
# core, so this Atlas-side write is the whole indexing path.
#
# `all_text_timv` is the Blacklight catch-all (already in the request handler's
# qf and the copyField destination of the *_tsim/*_ssim families), so writing
# here makes the text *searchable* with no schema change. Highlighting the
# snippet additionally needs the field `stored="true"` in the Solr image — see
# the blacklight-solr gap report; searchability does not depend on it.
#
# Empty hash for non-Works and for a Work whose text hasn't been extracted yet
# (the field appears once Cerberus PATCHes it and the Work is next saved).
class FullTextIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    text = resource.full_text
    return {} if text.blank?

    { all_text_timv: text }
  end
end
