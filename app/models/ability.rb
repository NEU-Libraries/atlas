# frozen_string_literal: true

# Wire-level authorization for the JSON API. Every controller action consults
# this matrix via `authorize!`; the application_controller `check_authorization`
# hook raises CanCan::AuthorizationNotPerformed if an action forgets to call
# authorize, so the piece-2 footgun ("add :reject_system_principal to every
# new write action") is structurally impossible.
#
# Companion layer: Cerberus has its own Ability (UI-gating concern — controls
# whether buttons render). Atlas's Ability is the deep-defense / system-of-
# record layer; Cerberus is the user-experience layer. Divergence between the
# two is recoverable rather than a privilege escalation: if Atlas says "no"
# but Cerberus said "yes," the user sees an actionable element that 403s when
# clicked. If Cerberus says "no" but Atlas says "yes," a direct API caller
# can still reach Atlas — Atlas's Ability is then the effective gate.
#
# Conventions for callers:
#  - **Class-level check** (`authorize! :create, Work`) when the decision does
#    NOT depend on the resource's state. Use for :create, admin-only :destroy,
#    :read on resource classes, and verbs targeting models with no per-row
#    ACL (User, AuditEvent).
#  - **Instance-level check** (`authorize! :update, @work`) when the decision
#    DOES depend on resource state. The group-ACL block-form rules below need
#    a concrete resource to read edit_users / edit_groups from; bare class
#    checks would silently pass for users who don't have ACL access.
class Ability
  include CanCan::Ability

  # update_thumbnails / update_image_derivatives / update_iiif_service /
  # complete travel with :update for the purposes of ACL gating — they all
  # mutate the resource's state and callers who can :update can do these
  # too. Keeps the group-ACL block-form rules to a single :update
  # declaration per resource class.
  #
  # :reparent and :link_member are intentionally NOT aliased here and are NOT
  # granted to any role except :admin (which carries them via `manage :all`).
  # Re-parenting a node and linking a Work into additional Collections are
  # structural mutations of the content graph; the matching Cerberus UI is
  # admin-only, and Atlas is the real boundary, so edit-rights no longer
  # implies either. Non-admins get a clean 403.
  UPDATE_ALIASES = %i[update_thumbnails update_image_derivatives update_iiif_service complete].freeze

  def initialize(user)
    # @current_user is never nil under piece-2 require_auth — at worst it
    # falls through to the :guest fixture. Guard anyway so Ability can be
    # constructed in isolation (specs, console) and so a missing guest
    # row in the test DB doesn't crash the controller.
    user ||= User.find_by(role: :guest)

    alias_action(*UPDATE_ALIASES, to: :update)

    # Hard floor: :anonymous never authenticates and never carries ability,
    # and a nil user (no guest fixture present) carries none either.
    # require_auth 401s before reaching here in production; this is
    # belt-and-suspenders.
    return if user.nil? || user.anonymous?

    # Read floor: any authenticated principal (incl. :guest) can read every
    # repository resource. Visibility lives on the resource itself
    # (Permissions concern); Atlas defers to it.
    can :read, Resource

    apply_role_abilities(user)
    apply_group_abilities(user)
    apply_compilation_abilities(user)
  end

  private

    def apply_role_abilities(user)
      case user.role.to_sym
      when :system
        # Non-human bookend. Tightly enumerated: SSO user provisioning +
        # JWT mint, plus the Q7 carve-out for container creation so the
        # seed task can bootstrap Communities/Collections. The piece-2
        # reject_system_principal sprinkle is what this list replaces —
        # :system explicitly cannot author Works, mutate any resource, or
        # tombstone/restore/destroy anything.
        can :provision,  User
        can :mint_token, User
        can :read,       User
        can :create,     Community
        can :create,     Collection
        # Operational Solr re-projection (POST /resources/:id/reindex[_subtree]).
        # Side-effect-free (no Postgres write, no lifecycle/audit) — re-derives
        # the Solr doc after an indexer ships/changes. An operational action,
        # never a user one, so it lives here on the :system tier (admin reaches
        # it via the manage :all wildcard, like :reparent).
        can :reindex,    Resource
        # Person curation — create + edit authority fields + manage affiliations
        # (affiliation add/remove ride :update). Name authority and affiliations
        # are operational/curatorial, not a self-service user action, so they
        # live on the :system tier; admin reaches them via manage :all. Reads
        # stay on the `can :read, Resource` floor above (Person < Resource).
        can %i[create update], Person
      when :guest
        # Read floor only. Devise /user shape lets guests fetch their own
        # session info — no resource-modifying ability.
        can :read, User
      when :standard, :loader, :privileged
        # All three authenticate as standard humans at Atlas's wire. Their
        # role-derived UI differentiation (loader's batch-ingest surface,
        # privileged's proxy-upload radio) lives in Cerberus's Ability
        # layer; Atlas's endpoints don't distinguish at the wire level. If
        # a future piece adds an Atlas-side rule keyed on :loader or
        # :privileged, split this case out then — don't pre-encode rules
        # for endpoints Atlas doesn't expose.
        can :read,    User
        can :preview, Resource

        # Container + Work creation. Group ACLs gate per-instance updates;
        # creates are class-level (no resource to inspect yet).
        can :create, Work
        can :create, Community
        can :create, Collection

        # Personal Sets — any signed-in human can curate their own (matches
        # v1's "any signed-in user"; flagged decision F3). Guests cannot.
        can :create, Compilation

        # FileSet / Blob writes are not group-ACL-gated at the wire — they
        # hang off Works and Atlas doesn't cheaply trace FS→Work ownership.
        # The role gate at Work creation is the entry barrier; once you
        # can author a Work, you can attach FileSets and Blobs to it.
        # :destroy intentionally absent — admin only.
        can %i[create update], FileSet
        can %i[create update], Blob
      when :admin
        # The wildcard. Minimal membership by design; bypasses both role
        # enumeration and group ACLs.
        can :manage, :all
      end
    end

    def apply_group_abilities(user)
      return if user.admin?      # wildcard already granted
      return if user.system?     # non-human; no group axis
      return if user.anonymous?  # never authenticates
      return if user.guest?      # read floor only

      [Work, Collection, Community].each do |klass|
        can %i[update tombstone restore], klass do |resource|
          group_acl_grants?(resource, user)
        end
      end
    end

    # Compilations (personal Sets) diverge from the `can :read, Resource`
    # floor: visibility is per-row (owner / ACL / public), because public? is
    # what anonymous (guest) CERES traffic rides on — so the :read rule is
    # granted to :guest too. Unlike the resource read floor it leaks nothing
    # non-public. Owner + explicit grants only on the write side; there is
    # deliberately NO staff default (F2) — :admin covers via the wildcard.
    def apply_compilation_abilities(user)
      return if user.admin?      # wildcard already granted
      return if user.system?     # non-human; Sets are personal curation
      return if user.anonymous?  # never authenticates

      can :read, Compilation do |comp|
        compilation_readable?(comp, user)
      end
      return if user.guest?

      can %i[update destroy], Compilation do |comp|
        comp.depositor == user.nuid || group_acl_grants?(comp, user)
      end
    end

    # Per-row Set visibility: public, owned, read-group match, or any edit
    # grant (edit implies read).
    def compilation_readable?(comp, user)
      comp.public? ||
        comp.depositor == user.nuid ||
        (Array(comp.read_groups) & Array(user.groups)).any? ||
        group_acl_grants?(comp, user)
    end

    # Group ACL match: caller's NUID is in the resource's edit_users list, OR
    # any of the caller's groups intersect the resource's edit_groups. Shape
    # mirrors the Cerberus-side check; both layers consult the same envelope.
    def group_acl_grants?(resource, user)
      return false if resource.nil?

      Array(resource.edit_users).include?(user.nuid) ||
        (Array(resource.edit_groups) & Array(user.groups)).any?
    end
end
