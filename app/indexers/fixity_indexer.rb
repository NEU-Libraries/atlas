# frozen_string_literal: true

# Projects the latest fixity check on the object a resource owns, so an admin
# can facet on what failed or what is overdue without reading storage. Stored
# (`_dtsi`), so a range query can find "not checked since". See
# docs/fixity.md.
#
# Absent, not empty, for an object never checked: a "never checked" query is
# then `-fixity_checked_at_dtsi:[* TO *]`.
class FixityIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} if resource.is_a?(Delegate) || resource.try(:noid).blank?

    row = FixityResult.find_by(object_key: resource.noid)
    return {} if row.nil?

    { fixity_checked_at_dtsi: row.checked_at.utc.iso8601, fixity_result_ssi: row.result }
  end
end
