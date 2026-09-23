# frozen_string_literal: true

# Wire-level authorization for the JSON API. Every controller action consults
# this matrix via `authorize!`. See docs/authorization.md for the tiers, the
# two-layer model with Cerberus, and the reasoning behind each carve-out.
#
# The one rule to know before editing: a block-form rule cannot evaluate
# against a class, and cancancan lets `authorize! :read, Work` through. Callers
# authorize an INSTANCE for any verb whose rule reads the resource's own ACL —
# `authorize! :read, work || Work`, keeping the class fallback so an
# unresolvable id 404s instead of tripping check_authorization.
class Ability
  include CanCan::Ability

  # Machine-set derived-metadata verbs that ride :update for ACL gating.
  #
  # :reparent, :link_member, :restore and :associate are deliberately absent
  # and must stay absent — they are operator verbs, and adding one here would
  # grant it to every principal holding edit rights.
  UPDATE_ALIASES = %i[update_thumbnails update_image_derivatives update_derivative_permissions
                      update_iiif_service update_full_text complete
                      mark_incomplete clear_incomplete].freeze

  def initialize(user, on_behalf_of: nil)
    # Never nil under require_auth (it falls through to the :guest fixture).
    # Guarded so Ability still constructs in a spec or console, and so a
    # missing guest row in the test DB doesn't crash the controller.
    user ||= User.find_by(role: :guest)
    @on_behalf_of = on_behalf_of

    alias_action(*UPDATE_ALIASES, to: :update)

    # Hard floor: :anonymous never authenticates, and a nil user carries no
    # ability either. require_auth 401s before reaching here in production.
    return if user.nil? || user.anonymous?

    # Block-form on purpose, and every caller must pass an instance — see the
    # class header. spec/models/ability_spec.rb fails if this rule ever loses
    # its condition.
    can :read, Resource do |resource|
      resource_readable?(resource, user)
    end

    # Cerberus polls the maintenance flag to render its banner and write gate,
    # so it must stay readable while the window it describes is open.
    can :read, :maintenance

    # The search itself; the per-document decision is the query's read gate.
    can :read, :catalog

    apply_role_abilities(user)
    apply_group_abilities(user)
    apply_compilation_abilities(user)
    apply_admin_delegate_abilities(user)
  end

  private

    def apply_role_abilities(user)
      case user.role.to_sym
      when :system
        can :provision,  User
        can :mint_token, User
        # Reads past the per-resource gate. Declared here rather than in the
        # base rule so it comes LAST and wins; moving it earlier re-gates the
        # backend and breaks showcase publishing and the reindexes.
        can :read, Resource
        can :maintain,       :maintenance
        can :read,           User
        can :read_directory, User
        can :create,         Community
        can :create,         Collection
        # The container half of the seed carve-out. The pair is what keeps
        # Works out of reach: a Work create still fails the class-level
        # `:create, Work` check even though its parent passes here.
        can :create_child, [Community, Collection]
        can :reindex, Resource
        can %i[create update], Person

        # Scoped on both sides: only a featured Collection, and only a Work
        # owned by the asserted on_behalf_of target.
        can :link_member, Collection, &:featured
        can :link_member, Work do |work|
          @on_behalf_of.present? && work.depositor == @on_behalf_of
        end
      when :guest
        # `GET /user` only. NOT :read_directory — the directory answers
        # name-and-NUID for any fragment, which is an enumeration risk.
        can :read, User
      when :standard, :loader, :privileged
        # All three are standard humans at Atlas's wire; the role-derived
        # differences live in Cerberus's Ability.
        can :read,           User
        can :read_directory, User
        can :preview,        Resource

        # The type half only. Which container the child lands in is decided
        # per-instance by :create_child in apply_group_abilities.
        can :create, Work
        can :create, Community
        can :create, Collection

        can :create, Compilation

        # Not group-ACL-gated at the wire: leaves hang off Works and Atlas
        # cannot cheaply trace FileSet -> Work ownership. :destroy is admin
        # only, deliberately.
        can %i[create update], FileSet
        can %i[create update], Blob
      when :admin
        can :manage, :all
      end
    end

    def apply_group_abilities(user)
      return if user.admin?      # wildcard already granted
      return if user.system?     # non-human; no group axis
      return if user.anonymous?  # never authenticates
      return if user.guest?      # the read gate only; no write rules

      [Work, Collection, Community].each do |klass|
        can %i[update tombstone], klass do |resource|
          edit_grants?(resource, user)
        end
      end

      # The subject is the CONTAINER the child lands in, never the child. A
      # Work is never a container of Works or Collections, so only these two
      # types can be the subject.
      can :create_child, [Collection, Community] do |parent|
        edit_grants?(parent, user)
      end
    end

    # A Compilation is an AR row, not a Resource, so it carries its own
    # visibility rather than riding the resource gate. :read reaches :guest
    # because public? is what anonymous traffic rides on.
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

    # Devolved-admin tier, keyed on User#admin_delegate? (the :privileged role
    # and Permissions::ADMIN_GROUP jointly — neither alone suffices). Each
    # grant is a named carve-out below :admin's wildcard; docs/authorization.md
    # gives the argument for each one.
    def apply_admin_delegate_abilities(user)
      return unless user.admin_delegate?

      can :reparent,  [Work, Collection, Community]
      can :restore,   [Work, Collection, Community]
      can :associate, Work
      can :create, AuditEvent
      can :read_versions, [Blob, Work, Collection, Community]
    end

    # A nil authority denies. That covers an unresolvable resource and an
    # unattached leaf, and deny is the safe answer for both.
    def resource_readable?(resource, user)
      authority = resource&.read_authority
      return false if authority.nil?

      authority.public? ||
        Array(authority.read_groups).intersect?(Array(user.groups)) ||
        edit_grants?(authority, user)
    end

    def compilation_readable?(comp, user)
      comp.public? ||
        comp.depositor == user.nuid ||
        Array(comp.read_groups).intersect?(Array(user.groups)) ||
        group_acl_grants?(comp, user)
    end

    # The ACL half alone. Shape mirrors the Cerberus-side check; both layers
    # consult the same envelope.
    def group_acl_grants?(resource, user)
      return false if resource.nil?

      Array(resource.edit_users).include?(user.nuid) ||
        Array(resource.edit_groups).intersect?(Array(user.groups))
    end

    # Ownership has to count separately because it is not in the ACL: a
    # personal root carries `edit: [repository:staff]` with the owner recorded
    # only as depositor, so narrowing this to the ACL locks a non-staff owner
    # out of their own workspace.
    def edit_grants?(resource, user)
      return false if resource.nil?

      group_acl_grants?(resource, user) ||
        (resource.depositor.present? && resource.depositor == user.nuid)
    end
end
