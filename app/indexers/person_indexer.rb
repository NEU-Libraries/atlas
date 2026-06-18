# frozen_string_literal: true

# Projects a Person onto its Solr doc so the People surface and the
# community-scoped Faculty-and-Staff browse can be Blacklight result sets.
#
# - display_name_ssi: the authoritative, librarian-editable name (single-value
#   string) — what every name render should resolve to.
# - nuid_ssi: the correlation key, for NUID-keyed lookups / profile gating.
# - affiliated_community_ids_ssim: the affiliated communities as NOIDs (the
#   public id, matching ancestor_ids_ssim's noid shape), so a community page can
#   pull its affiliated Persons with one fq=affiliated_community_ids_ssim:"<noid>".
#
# Empty hash for everything that isn't a Person. Valkyrie's solr persister sets
# internal_resource on the doc, so Cerberus's type-allowlisted catalog naturally
# excludes Person without any extra flag here.
class PersonIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Person)

    {
      display_name_ssi:              resource.display_name,
      nuid_ssi:                      resource.nuid,
      affiliated_community_ids_ssim: affiliated_noids
    }
  end

  private

    # Resolve the stored Valkyrie ids to community NOIDs (a handful per Person;
    # one batched query). Empty when the Person has no affiliations.
    def affiliated_noids
      ids = Array(resource.affiliated_community_ids)
      return [] if ids.empty?

      Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
    end
end
