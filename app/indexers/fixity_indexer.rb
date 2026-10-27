# frozen_string_literal: true

# Projects the latest fixity check on the object a resource owns, so an admin
# report can find what failed or what is overdue without reading storage.
# Preservation detail for staff, never for public discovery. Stored (`_dtsi`),
# so a range query can find "not checked since". See docs/fixity.md.
#
# Absent, not empty, for an object never checked: a "never checked" query is
# then `-fixity_checked_at_dtsi:[* TO *]`.
#
# A Work also carries the rollup over every object it owns (work_fixity_*),
# because the catalog hides FileSet and Blob docs and Solr cannot take a
# minimum across them per Work.
class FixityIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} if resource.is_a?(Delegate) || resource.try(:noid).blank?

    own_fields.merge(resource.is_a?(Work) ? work_fields : {})
  end

  private

    def own_fields
      row = FixityResult.find_by(object_key: resource.noid)
      return {} if row.nil?

      { fixity_checked_at_dtsi: row.checked_at.utc.iso8601, fixity_result_ssi: row.result }
    end

    def work_fields
      summary = FixityResult.summary(PreservedObjectKeysQuery.keys_for(resource))
      { work_fixity_checked_at_dtsi:   summary[:last_checked_at],
        work_fixity_result_ssi:        summary[:result],
        work_fixity_objects_isi:       summary[:objects],
        work_fixity_never_checked_isi: summary[:never_checked] }.compact
    end
end
