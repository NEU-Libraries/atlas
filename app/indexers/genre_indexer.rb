# frozen_string_literal: true

# Projects a Work's MODS genre(s) onto the Work's own Solr doc so Cerberus's
# catalog can offer a scholarly-category facet — the v1 "category" dimension
# (Research Publications, Presentations, Datasets, ...) reborn over v2's
# mods:genre. Drives the themed homepage gateways, the per-person
# published-by-category breakdown, and a Content/Genre narrow on browse.
#
# Genre lives in the JSON access copy (Metadata::MODS#genres, an array
# extracted from /mods:mods/mods:genre), reachable on any Modsable resource via
# resource.mods. This indexer reads it straight off the resource and writes a
# multivalued string field — the projected values ARE the genre strings, so the
# facet needs no value-mapping downstream. Mirrors ClassificationIndexer's
# "project a metadata value onto the Work doc" shape, but sourced from MODS
# genre rather than child FileSet format types (a distinct dimension).
#
# Empty hash for anything that isn't a Work (the facet is over Works) and for a
# Work with no genre yet — the field appears once a genre is set and the Work is
# next saved (composite save, e.g. POST /works/:id/complete or a reindex).
class GenreIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    genres = Array(resource.mods&.genres).compact.uniq
    return {} if genres.empty?

    { genre_ssim: genres }
  end
end
