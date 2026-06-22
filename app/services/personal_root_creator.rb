# frozen_string_literal: true

# Mints (or returns) a Person's personal-root Collection — the stable
# structural parent the publish conduit writes a depositor's own Works under.
# Mirrors v1's per-Employee "User Root", but one root per Person rather than
# v1's 8-folders-per-person sprawl.
#
# Parent strategy (see gap_reports/atlas_person_personal_root.md, "Parent
# question"): every personal root hangs under a SINGLE singleton system "People"
# Community, not the person's affiliated community. This keeps the root
# affiliation-independent — a Person may publish across several affiliated
# communities, and the root must not move when affiliations change. It also lets
# the root be minted eagerly at Person.create, before any affiliation exists.
#
# The singleton is found-or-created idempotently, marked by the sentinel
# depositor "system" (no new Community attribute; the marker serializes into the
# on-disk preservation envelope naturally). There are only a handful of
# Communities, so the linear find_all_of_model scan is cheap.
#
# Provisioning here is an unattributed system side effect: the root and the
# People Community are created WITHOUT an actor_nuid, so CollectionCreator /
# CommunityCreator emit no structural audit rows for them (the user-facing audit
# is the Person create itself).
class PersonalRootCreator < ApplicationService
  # Sentinel marking the singleton People Community. Not a real NUID — "system"
  # owns the container all personal roots hang under.
  PEOPLE_COMMUNITY_DEPOSITOR = 'system'

  def initialize(nuid:)
    @nuid = nuid
  end

  def call
    CollectionCreator.call(parent_id: people_community.id, depositor: @nuid, mods_xml: titled_mods('Personal Root'))
  end

  private

    # Find-or-create the singleton "People" Community. Idempotent: a second
    # caller (concurrent create, backfill re-run) reuses the existing one.
    def people_community
      existing = Atlas.query.find_all_of_model(model: Community)
                      .find { |c| c.depositor == PEOPLE_COMMUNITY_DEPOSITOR }
      existing || CommunityCreator.call(depositor: PEOPLE_COMMUNITY_DEPOSITOR, mods_xml: titled_mods('People'))
    end

    # The empty MODS template with its primary title set, so the on-disk
    # envelope is human-recoverable (a bare "" title would be opaque to the
    # bus-factor new hire). Nokogiri here is the write path — fine; the smell is
    # parsing MODS on the read path.
    def titled_mods(title)
      doc = Nokogiri::XML(mods_template)
      doc.at_xpath('//mods:titleInfo[@usage="primary"]/mods:title',
                   'mods' => 'http://www.loc.gov/mods/v3').content = title
      doc.to_xml
    end
end
