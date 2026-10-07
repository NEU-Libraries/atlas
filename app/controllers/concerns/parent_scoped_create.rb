# frozen_string_literal: true

# The container half of the create gate, shared by Works, Collections, and
# Communities. Each controller's `create` authorizes twice: `:create` on the
# class (may this principal author this type at all) and `:create_child` on the
# resolved parent (may they write into THIS container). Without the second
# check, `parent_id` flows straight from the request into the Creator and any
# authenticated human can write a child into a container they cannot edit — or
# even read — inheriting that container's ACL.
#
# A tombstoned container refuses the create, as it refuses a restore or a
# re-parent into it: a new child would be discoverable inside a withdrawn
# container. See docs/resource-graph.md.
module ParentScopedCreate
  extend ActiveSupport::Concern

  included do
    rescue_from Exceptions::TombstonedParent do |exception|
      render json:   { error: exception.message, code: Exceptions::TombstonedParent::CODE },
             status: :unprocessable_content
    end
  end

  private

    # Resolve the parent named by the request and authorize the create against
    # it. Returns nil for a blank or unresolvable `parent_id`; the caller
    # decides what that means — a 404 for Works and Collections, which always
    # require a parent, or a legitimate top-of-tree create for a Community.
    #
    # A blank id names no container to consult, so the class-level `:create`
    # check is the whole gate in that case. A present-but-unresolvable id is
    # authorized against nil (before the nil reaches the caller) so
    # `check_authorization` is satisfied on the not-found path, mirroring the
    # member actions: an admin passes the nil check and the caller 404s, while a
    # non-admin is denied without learning whether the id exists.
    def authorized_create_parent(parent_id)
      return nil if parent_id.blank?

      parent = Resource.find(parent_id)
      authorize! :create_child, parent
      # After the authorize, so a caller without rights learns nothing of the
      # parent's state.
      raise Exceptions::TombstonedParent if parent&.tombstoned

      parent
    end
end
