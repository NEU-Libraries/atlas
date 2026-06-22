# frozen_string_literal: true

# Projects a Person onto its Solr doc so the People surface and the
# community-scoped Faculty-and-Staff browse can be Blacklight result sets.
#
# - title_tsim: display_name projected into the standard title field every
#   other resource type uses (MODSIndexer sets it from plain_title). This is
#   what makes a Person a first-class Blacklight result: Cerberus *displays* it
#   (index.title_field) and *keyword-searches* it (qf targets tokenized *_tsim),
#   so `q=David Cliff` matches the Person and the row renders with a name rather
#   than falling back to the id. (display_name is auto-indexed as
#   display_name_tsim too, but qf targets the title field, not that one.)
# - type_ssim: ['Person'] so Person is a Type-facet value alongside
#   Work/Collection/Community. Overrides the auto-projected `type` attribute
#   (which is the human label "Faculty and Staff") for the facet field only;
#   the type attribute and its other Solr variants are untouched.
# - display_name_ssi: the authoritative, librarian-editable name (single-value
#   string) — what every name render should resolve to.
# - noid_ssi: the public address. The community Faculty-and-Staff browse finds
#   Person docs via affiliated_community_ids_ssim and links to /people/:noid, so
#   it needs the NOID explicitly (rather than parsing alternate_ids).
# - nuid_ssi: the correlation key, server-side only (NUID-keyed lookups /
#   depositor gating); never the public address. (NB: the NUID is NOT added to
#   any title/searchable field here — IT Security: no NUID in search responses.)
# - affiliated_community_ids_ssim: the affiliated communities as NOIDs (the
#   public id, matching ancestor_ids_ssim's noid shape), so a community page can
#   pull its affiliated Persons with one fq=affiliated_community_ids_ssim:"<noid>".
# - personal_root_id_ssi: NOID of the Person's personal-root Collection. Not
#   required by Cerberus (it reads personal_root_id off the Person JSON); indexed
#   for discovery + to verify provisioning straight from Solr.
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

    # Resolve the stored Valkyrie ids to community NOIDs (a handful per Person;
    # one batched query). Empty when the Person has no affiliations.
    def affiliated_noids
      ids = Array(resource.affiliated_community_ids)
      return [] if ids.empty?

      Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
    end
end
