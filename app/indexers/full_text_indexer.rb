# frozen_string_literal: true

# Projects a Work's derived full-document text onto its own Solr doc as the
# dedicated `full_text_tesimv` field, so Cerberus's catalog can match body-text
# queries and render the "Full Text Match" result snippet.
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
# `full_text_tesimv` is a DEDICATED extracted-text field — it carries the
# document body and nothing else. This deliberately replaces the original
# `all_text_timv` target: that name is a *catch-all* in Atlas's v2 schema (it
# concatenates ACL group names, depositor NUIDs, ids, labels, IIIF URLs, …), so
# routing body text there leaked internal data into public snippets and made
# infrastructure tokens match user searches. With a dedicated field, resources
# with no document text (Communities/Collections/Delegates/FileSets) get no
# field at all and never false-match or render a snippet.
#
# The `*_tesimv` dynamic field is text_en, stored, multi-valued, with
# termVectors/termPositions/termOffsets — i.e. FastVectorHighlighter-ready, so
# Cerberus's `hl.method=fastVector` snippet works against it directly. For
# body-text *search* the field must be in the request handler's `qf` (the
# blacklight-solr image owns that; it is not a copyField destination like the
# catch-all was).
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

    { full_text_tesimv: text }
  end
end
