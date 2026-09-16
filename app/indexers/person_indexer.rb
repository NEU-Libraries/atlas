# frozen_string_literal: true

# Projects a Person onto its Solr doc so the People surface and the
# community-scoped Faculty-and-Staff browse can be Blacklight result sets. See
# docs/solr-indexing.md for what each field feeds.
#
# A Person reaches ORDINARY catalog results, so treat one as a first-class
# result throughout, not a People-surface special case. The NUID is never added
# to a title or searchable field -- IT Security: no NUID in search responses.
class PersonIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Person)

    {
      # title_tsim explicitly, because qf targets the title field and not the
      # auto-indexed display_name_tsim. type_ssim overrides the auto-projected
      # `type` attribute for the facet field only.
      title_tsim:                    [resource.display_name],
      type_ssim:                     ['Person'],
      noid_ssi:                      resource.noid,
      display_name_ssi:              resource.display_name,
      nuid_ssi:                      resource.nuid,
      affiliated_community_ids_ssim: affiliated_noids,
      personal_root_id_ssi:          resource.personal_root_id
    }
  end

  private

    # NOIDs rather than Valkyrie ids, matching ancestor_ids_ssim's shape so a
    # community page pulls its Persons with one fq. One batched query.
    def affiliated_noids
      ids = Array(resource.affiliated_community_ids)
      return [] if ids.empty?

      Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
    end
end
