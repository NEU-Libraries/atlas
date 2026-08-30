# frozen_string_literal: true

# Read gating for the resources that hang off a Work or container and carry no
# ACL of their own worth trusting: FileSet, Blob, Delegate.
#
# Each creator copies the parent's ACL onto the leaf at creation
# (FileSetCreator, BlobCreator, DelegateCreator), but nothing rewrites that
# copy afterwards — Cerberus's narrowing cascade walks Works and containers
# only. So a leaf's own read_groups records what its parent allowed the day it
# was made, not what the parent allows now. Gating on it would keep serving the
# bytes of a Work that has since been closed.
#
# Walking to the parent costs a query per hop, and a Blob sits two hops below
# its Work (Blob -> FileSet -> Work). That is deliberate: this runs on the
# binary read path, where correctness outranks the round trip, and never on
# the Work read path.
module LeafReadAuthority
  extend ActiveSupport::Concern

  # The tree is Community > Collection > Work > FileSet > Blob, so a leaf
  # reaches an answering ancestor in at most two hops. The cap also stops a
  # corrupt parent chain from looping here — Relationships#ancestor_resources
  # raises on a cycle, but this walk is its own and must not depend on that.
  MAX_HOPS = 2

  # nil when no Work or container answers for this leaf, which callers read as
  # "deny". An unattached Blob — created but not yet joined to a FileSet — has
  # nobody to speak for it, and guessing would defeat the gate.
  def read_authority
    node = self

    MAX_HOPS.times do
      node = node.parent
      return nil if node.nil?
      return node if node.is_a?(Work) || node.is_a?(Collection) || node.is_a?(Community)
    end

    nil
  end
end
