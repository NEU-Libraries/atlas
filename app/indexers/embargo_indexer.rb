# frozen_string_literal: true

# Projects a Work's embargo release date onto its Solr document, so Cerberus's
# catalog can show the "Embargoed" thumbnail pill and the "Contents available
# <date>" notice without a live Atlas call. The download gate reads
# permissions.embargo off Atlas directly; this field only feeds display.
#
# Only the date is indexed, never an "is embargoed" flag. A flag is true when
# written and false once the date passes, and nothing re-indexes a Work on its
# release date. Readers compute the state with Permissions.embargo_active?.
#
# Work-only, because Cerberus surfaces the field only for Works. #presence
# keeps the setter's '' "no embargo" shape out of a Solr date field.
class EmbargoIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    { embargo_release_date_dtsi: resource.embargo_release_date.presence }
  end
end
