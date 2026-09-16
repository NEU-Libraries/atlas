# frozen_string_literal: true

# Mints (or returns) a Person's personal-root Collection. See docs/people.md.
#
# Every root hangs under a SINGLE singleton "People" Community rather than the
# person's affiliated community, so the root is affiliation-independent and
# can be minted before any affiliation exists.
#
# Unattributed on purpose: no actor_nuid, so the creators emit no structural
# audit rows. The Person create is the audit.
class PersonalRootCreator < ApplicationService
  # Not a real NUID: the sentinel marking the singleton People Community.
  PEOPLE_COMMUNITY_DEPOSITOR = 'system'

  def initialize(nuid:)
    @nuid = nuid
  end

  def call
    root = CollectionCreator.call(parent_id: people_community.id, depositor: @nuid,
                                  mods_xml: titled_mods('Personal Root'))

    # The People Community has no public read grant, so a root that merely
    # INHERITED its ACL would 403 for its own owner -- and collections made
    # under it would inherit those non-readable permissions. The re-save and
    # envelope re-write put the grant on disk too.
    root.publicize
    root.personal_root = true
    root = Atlas.persister.save(resource: root)
    root.write_preservation_envelope!
    root
  end

  private

    # Idempotent: a concurrent create or backfill re-run reuses the existing.
    def people_community
      existing = Atlas.query.find_all_of_model(model: Community)
                      .find { |c| c.depositor == PEOPLE_COMMUNITY_DEPOSITOR }
      ensure_system_container(existing || create_people_community)
    end

    def create_people_community
      CommunityCreator.call(depositor: PEOPLE_COMMUNITY_DEPOSITOR, mods_xml: titled_mods('People'))
    end

    # Self-healing: a People Community minted before this flag existed
    # acquires it, and re-projects to Solr, on the next Person create.
    def ensure_system_container(community)
      return community if community.system_container

      community.system_container = true
      Atlas.persister.save(resource: community)
    end

    # A title so the on-disk envelope is human-recoverable; a bare "" would be
    # opaque to the bus-factor new hire. Nokogiri on the WRITE path is fine --
    # the smell is parsing MODS on a read path.
    def titled_mods(title)
      doc = Nokogiri::XML(mods_template)
      doc.at_xpath('//mods:titleInfo[@usage="primary"]/mods:title',
                   'mods' => 'http://www.loc.gov/mods/v3').content = title
      doc.to_xml
    end
end
