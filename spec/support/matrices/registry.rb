# frozen_string_literal: true

require_relative 'axes'
require_relative 'access_matrix'
require_relative 'write_matrix'

# What bin/acl-coverage reads beyond the matrix tables: which matrices exist,
# which controllers act on the resource tree, and the written reasons for the
# actions that skip a gate on purpose. A reason here is the only way to skip
# one: an action with neither the gate nor a reason fails the coverage check.
# See docs/testing.md.
module ACLMatrices
  ALL = { read: AccessMatrix, write: WriteMatrix }.freeze

  # Controllers whose :id names a Resource, so an action keyed on it must
  # refuse a tombstone or say here why it does not.
  RESOURCE_CONTROLLERS = %w[works collections communities file_sets blobs delegates resources darwin_core
                            resource_children index_documents search_explanations audit_events].freeze

  # Any one of these, reached from the action, counts as the tombstone gate.
  TOMBSTONE_GATES = %i[refuse_tombstoned! render_tombstone_stub tombstone_withheld?].freeze

  TOMBSTONE_EXEMPT = {
    'resources#restore'          => 'its target is tombstoned by definition',
    'resources#destroy'          => 'admin-only, and a purge must reach a tombstoned resource',
    'blobs#destroy'              => 'admin-only, and a purge must reach a tombstoned resource',
    'file_sets#destroy'          => 'admin-only, and a purge must reach a tombstoned resource',
    'resources#reindex'          => "a withheld resource's Solr document must still be rebuildable",
    'resources#reindex_subtree'  => "a withheld resource's Solr document must still be rebuildable",
    'resources#show'             => 'a 302 to the typed route, which gates',
    'blobs#ancestry'             => 'NOIDs and tombstone flags only: how a client learns which ancestor withholds a file',
    'resources#descendant_works' => 'the Solr filter drops tombstoned Works',
    'blobs#versions'             => 'an operator-only verb; operators read past a tombstone',
    'darwin_core#versions'       => 'an operator-only verb; operators read past a tombstone',
    'resources#mods_versions'    => 'an operator-only verb; operators read past a tombstone',
    'works#health_check'         => 'an operator-only verb; operators read past a tombstone',
    'works#tombstoned_assets'    => 'an operator-only verb; operators read past a tombstone',
    'audit_events#index'         => 'an operator-only verb; operators read past a tombstone',
    'index_documents#show'       => 'an operator-only verb; operators read past a tombstone',
    'search_explanations#show'   => 'an operator-only verb; operators read past a tombstone',
    'resource_children#show'     => 'an operator-only verb; operators read past a tombstone'
  }.freeze

  # Actions that call no authorize! on purpose. check_authorization does not
  # reach a controller outside ApplicationController, so this list is the
  # only thing that does.
  PUBLIC = {
    'oai#index'         => 'the OAI-PMH protocol endpoint, outside ApplicationController',
    'docs#show'         => 'the API documentation, outside ApplicationController',
    'health#show'       => 'service health for the load balancer',
    'maintenance#reset' => 'the development data reset; RepositoryReset holds the environment guard'
  }.freeze
end
