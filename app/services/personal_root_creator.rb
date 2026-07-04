# frozen_string_literal: true

# Mints (or returns) a Person's personal-root Collection — the stable
# structural parent the publish conduit writes a depositor's own Works under.
# Mirrors v1's per-Employee "User Root", but one root per Person rather than
# v1's 8-folders-per-person sprawl.
#
# Parent strategy: every personal root hangs under a SINGLE singleton system
# "People" Community, not the person's affiliated community. This keeps the root
# affiliation-independent — a Person may publish across several affiliated
# communities, and the root must not move when affiliations change. It also lets
# the root be minted eagerly at Person.create, before any affiliation exists.
#
# The singleton is found-or-created idempotently, marked by the sentinel
# depositor "system" (which serializes into the on-disk preservation envelope
# naturally) and flagged system_container = true so Cerberus can exclude it from
# discovery. There are only a handful of Communities, so the linear
# find_all_of_model scan is cheap.
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
    root = CollectionCreator.call(parent_id: people_community.id, depositor: @nuid,
                                  mods_xml: titled_mods('Personal Root'))

    # Mint the root public-but-unpromoted. The People Community has no public
    # read grant, so a root that merely inherits its ACL 403s for its own owner — and
    # collections created under it inherit those non-readable permissions, so the
    # owner can't view a collection they just made. Publicizing the root makes it
    # owner-navigable and lets workspace collections inherit a public read,
    # keeping the hierarchy consistent (public child under public root); an owner
    # may still privatize an individual workspace collection later. Re-save +
    # re-write the envelope so the on-disk preservation copy carries the grant.
    #
    # Flag it a personal root (-> personal_root_bsi) so Cerberus can exclude it
    # from the global catalog and rewrite breadcrumbs around it — a personal root
    # is a structural container, not content.
    root.publicize
    root.personal_root = true
    root = Atlas.persister.save(resource: root)
    root.write_preservation_envelope!
    root
  end

  private

    # Find-or-create the singleton "People" Community. Idempotent: a second
    # caller (concurrent create, backfill re-run) reuses the existing one.
    def people_community
      existing = Atlas.query.find_all_of_model(model: Community)
                      .find { |c| c.depositor == PEOPLE_COMMUNITY_DEPOSITOR }
      ensure_system_container(existing || create_people_community)
    end

    def create_people_community
      CommunityCreator.call(depositor: PEOPLE_COMMUNITY_DEPOSITOR, mods_xml: titled_mods('People'))
    end

    # Mark the singleton a system container (-> system_container_bsi) so Cerberus
    # excludes it from the global catalog. Self-healing and idempotent: a People
    # Community minted before this flag existed acquires it — and re-projects to
    # Solr — on the next Person create; an already-flagged one is untouched.
    def ensure_system_container(community)
      return community if community.system_container

      community.system_container = true
      Atlas.persister.save(resource: community)
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
