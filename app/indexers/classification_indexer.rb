# frozen_string_literal: true

# Projects a Work's content classifications onto the Work's own Solr doc so
# Cerberus's catalog can offer a "Content" format facet.
#
# The Map/Image/Video/... values live on FileSet#type (assigned from MIME at
# deposit), one hop below the Work. Cerberus's catalog filters FileSet/Blob/
# Delegate docs out, so the facet has to read off the Work doc — this indexer
# gathers the distinct classifications of the Work's page FileSets and writes
# them up as a multivalued field. Mirrors ThumbnailIndexer's "project a
# child-derived value onto the parent doc" pattern; Atlas and Cerberus share
# one Solr core, so this Atlas-side write is the whole path.
#
# The projected values ARE the human Classification#name strings ('Image',
# 'Musical Notation', ...), so the facet needs no value-mapping downstream.
# Multivalued on purpose: a mixed-media Work surfaces under every type it
# holds. page_file_sets already excludes metadata/derivative FileSets.
#
# Empty hash for everything that isn't a Work (Collections/Communities carry
# child Works, not FileSets; Blobs/Delegates/FileSets have no page set) and
# for a Work with no pages yet (an in-progress deposit) — the field appears
# once content lands and the Work is next saved (at POST /works/:id/complete).
class ClassificationIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    types = resource.page_file_sets.map(&:type).compact.uniq
    return {} if types.empty?

    { classification_ssim: types }
  end
end
