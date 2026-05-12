# frozen_string_literal: true

class MODSIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    fields = {}

    # Operational flags get projected unconditionally so /works?in_progress
    # can find stuck deposits even before MODS metadata is filled in.
    fields[:in_progress_bsi] = resource.in_progress if resource.respond_to?(:in_progress)

    if decorated_resource.try(:plain_title)
      fields[:title_tsim] = decorated_resource.plain_title
      fields[:description_tsim] = decorated_resource.plain_description
      fields[:permanent_url_ssi] = decorated_resource.mods&.permanent_url
    end

    fields
  end

  def decorated_resource
    @decorated_resource ||= resource.decorate
  end
end
