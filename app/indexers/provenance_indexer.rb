# frozen_string_literal: true

# Projects the resource-level provenance fields (depositor, proxy_uploader)
# into Solr as single-value string indexes. These power Cerberus's hot-read
# permission checks — `Ability#depositor_for_work?` reads `depositor_ssi`
# on every page render, so the field must be O(1) at query time. The
# append-only history that explains how each value got there lives in
# AuditEvent, not Solr.
class ProvenanceIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    fields = {}
    fields[:depositor_ssi]      = resource.depositor      if resource.respond_to?(:depositor)
    fields[:proxy_uploader_ssi] = resource.proxy_uploader if resource.respond_to?(:proxy_uploader)
    fields
  end
end
