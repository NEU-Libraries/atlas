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

    # The pipeline-failure pair (Work#incomplete). Both go to Solr because a
    # consumer renders the "Incomplete" pill and its cause straight from the
    # search document — an unindexed field cannot drive it, and a per-row
    # fetch to read one flag would defeat the result list.
    if resource.respond_to?(:incomplete)
      fields[:incomplete_bsi]        = resource.incomplete
      fields[:incomplete_reason_ssi] = resource.incomplete_reason
    end

    if decorated_resource.try(:plain_title)
      fields[:title_tsim] = decorated_resource.plain_title
      fields[:description_tsim] = decorated_resource.plain_description
      fields[:permanent_url_ssi] = decorated_resource.mods&.permanent_url
      add_match_title(fields, decorated_resource.plain_title)
    end

    fields
  end

  def decorated_resource
    @decorated_resource ||= resource.decorate
  end

  private

    # title_tsim is both the match field and the display field a result row
    # renders, so it keeps the record's <sub>/<sup> markup -- which makes Solr
    # tokenise "sub" as a term of its own and leaves "Bi2Sr2CaCu2O8", the
    # formula a reader types, matching nothing. title_plain_tsim is the
    # match-only twin: the same title with the markup removed. Stripping
    # title_tsim instead would fix matching and break every result heading.
    #
    # Written only when the two differ, so an ordinary title is not indexed
    # twice. Being searched needs the field in the request handler's qf, which
    # the blacklight-solr image owns, as it does for full_text_tesimv.
    def add_match_title(fields, title)
      plain = EnhancedText.strip(title)
      fields[:title_plain_tsim] = plain unless plain == title
    end
end
