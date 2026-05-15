# frozen_string_literal: true

# Upserts a Delegate identified by (resource_id, use). Updates the
# existing Delegate's `uri` if one already exists for that role under
# the resource's `:derivative` FileSet; otherwise delegates to
# DelegateCreator to mint a new one (creating the derivative FileSet
# on first use).
class DelegateUpdater < ApplicationService
  def initialize(resource_id:, use:, uri:)
    @resource_id = resource_id
    @use         = use
    @uri         = uri
  end

  def call
    existing = find_existing
    return update(existing) if existing

    DelegateCreator.call(resource_id: @resource_id, use: @use, uri: @uri)
  end

  private

    def find_existing
      fs = derivative_file_set
      return nil unless fs

      Atlas.query.find_members(resource: fs).find do |m|
        m.is_a?(Delegate) && m.use == @use
      end
    end

    def derivative_file_set
      parent.children.find do |c|
        c.is_a?(FileSet) && c.type == Classification.derivative.name
      end
    end

    def parent
      @parent ||= Resource.find(@resource_id)
    end

    def update(delegate)
      delegate.uri = @uri
      saved = Atlas.persister.save(resource: delegate)
      # See DelegateCreator#reindex_parent! — the parent's Solr doc needs
      # an explicit re-save to pick up the new uri via ThumbnailIndexer.
      # The create branch goes through DelegateCreator, which handles its
      # own parent re-save.
      Atlas.persister.save(resource: Resource.find(@resource_id))
      saved
    end
end
