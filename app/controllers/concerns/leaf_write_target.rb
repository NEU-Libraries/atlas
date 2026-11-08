# frozen_string_literal: true

# The create half of the leaf write gate. A new FileSet or Blob has no ACL until
# it exists, so its create is authorized as :update on the Work it lands in.
# See docs/authorization.md.
module LeafWriteTarget
  extend ActiveSupport::Concern

  private

    # A blank or unresolvable id authorizes the class, so an admin reaches the
    # caller's 404 and a caller who could write nowhere gets the 403.
    def authorized_leaf_target(work_id)
      work = Resource.find(work_id) if work_id.present?
      authorize! :update, work || Work
      work
    end
end
