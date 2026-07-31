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
#
# Creating a resource takes BOTH checks: `:create` on the class answers "may
# this principal author this type at all" (a role question — :system may author
# containers but never Works), and `:create_child` on the resolved PARENT
# answers "may they write into this container" (an ACL question). The child has
# no state to inspect yet, but the container it lands in does, and writing into
# a container you don't control is the same class of structural mutation as
# :reparent. See ParentScopedCreate for the controller half.
class Ability
  include CanCan::Ability

  # update_thumbnails / update_image_derivatives / update_derivative_permissions /
  # update_iiif_service / update_full_text / complete travel with :update for the
  # purposes of ACL gating — they all mutate the resource's state (machine-set
  # derived metadata) and callers who can :update can do these too. Keeps the
  # group-ACL block-form rules to a single :update declaration per resource
  # class.
  #
  # :reparent and :link_member are intentionally NOT aliased here, and
  # non-admin HUMAN roles get neither via edit rights (group ACL below) —
  # both are structural mutations of the content graph; the matching
  # Cerberus UI is admin-only, and Atlas is the real boundary, so edit-rights
  # alone do not grant either. :system is one narrow non-admin exception: see
  # its scoped `:link_member` grant below (showcase publishing on a
  # depositor's behalf). The devolved-admin tier (apply_admin_delegate_abilities)
  # is the other: it gets an unconditional `:reparent` on Work/Collection/
  # Community — all three, since this ability never distinguished resource
  # types to begin with — (not via this alias list, and not via edit rights)
  # — see that method.
  #
  # :restore is withheld on the same reasoning even though its counterpart
  # :tombstone rides edit rights: reversing a withdrawal is an operator action,
  # so it lives with :reparent on the delegate tier.
  UPDATE_ALIASES = %i[update_thumbnails update_image_derivatives update_derivative_permissions
                      update_iiif_service update_full_text complete].freeze

  def initialize(user, on_behalf_of: nil)
    # @current_user is never nil under require_auth — at worst it
    # falls through to the :guest fixture. Guard anyway so Ability can be
    # constructed in isolation (specs, console) and so a missing guest
    # row in the test DB doesn't crash the controller.
    user ||= User.find_by(role: :guest)
    @on_behalf_of = on_behalf_of

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
    apply_admin_delegate_abilities(user)
  end

  private

    def apply_role_abilities(user)
      case user.role.to_sym
      when :system
        # Non-human bookend. Tightly enumerated: SSO user provisioning +
        # JWT mint, plus a carve-out for container creation so the seed task
        # can bootstrap Communities/Collections. Everything outside this list
        # is denied — :system explicitly cannot author Works, mutate any
        # resource, or tombstone/restore/destroy anything.
        can :provision,  User
        can :mint_token, User
        can :read,       User
        can :create,     Community
        can :create,     Collection
        # The container half of the seed carve-out: :create above says which
        # types :system may author, this says which containers it may write
        # into — unconditionally, since the seed bootstraps a tree it has no
        # ACL foothold in. The pair is what keeps Works out of reach: a Work
        # create still fails the class-level `:create, Work` check even though
        # its parent Collection passes here.
        can :create_child, [Community, Collection]
        # Operational Solr re-projection (POST /resources/:id/reindex[_subtree]).
        # Side-effect-free (no Postgres write, no lifecycle/audit) — re-derives
        # the Solr doc after an indexer ships/changes. An operational action,
        # never a user one, so it lives here on the :system tier (admin reaches
        # it via the manage :all wildcard, like :reparent).
        can :reindex, Resource
        # Person curation — create + edit authority fields + manage affiliations
        # (affiliation add/remove ride :update). Name authority and affiliations
        # are operational/curatorial, not a self-service user action, so they
        # live on the :system tier; admin reaches them via manage :all. Reads
        # stay on the `can :read, Resource` floor above (Person < Resource).
        can %i[create update], Person

        # Showcase publishing (Cerberus's "Publish to my community" deposit
        # branch): :system links a freshly-created Work into the depositor's
        # featured showcase Collection on their behalf, attributed downstream
        # via the on_behalf_of NUID (see enforce_on_behalf_of_gate). Scoped on
        # both sides so a Cerberus bug can't turn into more than "linked the
        # wrong work into a showcase" — :system still cannot mutate Collection
        # metadata, tombstone, or touch a non-featured Collection, and can
        # only link a Work owned by the asserted on_behalf_of target, never an
        # arbitrary (or private) Work.
        can :link_member, Collection, &:featured
        can :link_member, Work do |work|
          @on_behalf_of.present? && work.depositor == @on_behalf_of
        end
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

        # Container + Work creation — the type half only. Which container the
        # child may land in is decided per-instance by the `:create_child` rule
        # in apply_group_abilities. A parentless Community (top of tree) has no
        # container to consult, so this class check is the whole gate there.
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
        can %i[update tombstone], klass do |resource|
          edit_grants?(resource, user)
        end
      end

      # Parent-scoped create: the subject is the CONTAINER the new child lands
      # in, never the child. A Work is never a container of Works/Collections,
      # so only these two types can be the subject. FileSet/Blob creation hangs
      # off a Work and is deliberately not gated here (see the role branch).
      can :create_child, [Collection, Community] do |parent|
        edit_grants?(parent, user)
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
        edit_grants?(comp, user)
      end
    end

    # Devolved-admin tier, keyed on User#admin_delegate? (:privileged role +
    # Permissions::ADMIN_GROUP, jointly — neither alone is sufficient).
    # :admin already passes everything below via
    # the manage :all wildcard, so this method only needs to cover the
    # narrower delegate case. Each grant here is a deliberate, named carve-out
    # below :admin's wildcard, not a role/group promotion:
    #  - :reparent on Work/Collection/Community, all three — this Ability
    #    never distinguished resource types for :reparent to begin with, so
    #    the grant covers everything Reparentable exposes rather than being
    #    narrowed to whatever subset a caller's UI currently surfaces.
    #    Unconditional, system-wide, not scoped to the delegate's own
    #    edit_groups (see UPDATE_ALIASES comment above for why :reparent
    #    otherwise stays admin-only).
    #  - :create AuditEvent — unblocks Cerberus's impersonation session-start
    #    audit write (view-as and acting-as both call it before establishing
    #    a session). Unscoped rather than instance-conditioned on `mode`
    #    because POST /audit_events has exactly one caller system-wide;
    #    Cerberus's own act-as gate (admin-only, independent of Atlas) is
    #    what actually prevents a delegate from reaching acting-as.
    #  - :read_versions on Blob — a narrower verb than the generic
    #    `:read, AuditEvent` (audit-history tab) so this grant can't be
    #    mistaken for opening that surface; see BlobsController#versions.
    #  - :restore on Work/Collection/Community — reversing a tombstone is an
    #    operator action, not an owner or curator one, so it sits beside
    #    :reparent here rather than riding edit rights like :tombstone does.
    def apply_admin_delegate_abilities(user)
      return unless user.admin_delegate?

      can :reparent, [Work, Collection, Community]
      can :restore,  [Work, Collection, Community]
      can :create, AuditEvent
      can :read_versions, Blob
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

    # Edit-equivalent grant: an ACL match OR ownership. Ownership has to count
    # separately because it is not represented in the ACL — a personal root and
    # everything beneath it carries `edit: [repository:staff]` with the owner
    # recorded only as `depositor`, so a non-staff owner would otherwise be
    # locked out of their own workspace. A depositor may therefore edit,
    # withdraw, and deposit into their own resource independent of Grouper
    # membership; :restore is deliberately NOT one of those verbs (operator
    # only — see apply_admin_delegate_abilities).
    def edit_grants?(resource, user)
      return false if resource.nil?

      group_acl_grants?(resource, user) ||
        (resource.depositor.present? && resource.depositor == user.nuid)
    end
end
