# frozen_string_literal: true

# A tombstoned Work carries status="deleted" and nothing else — no metadata,
# no about. v1 never emitted this, so a tombstoned item stayed in Digital
# Commonwealth indefinitely.
#
# Every published Set the Work belongs to appears as a <setSpec>. v1 emitted
# none, because its record extension defined no `sets` method.
xml.header(record.deleted? ? { status: 'deleted' } : {}) do
  xml.identifier record.identifier
  xml.datestamp record.datestamp
  record.set_specs.each { |spec| xml.setSpec spec }
end
