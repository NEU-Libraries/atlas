# frozen_string_literal: true

# <metadata> is omitted, never emitted empty, in two cases: a deleted record
# (the protocol says a deleted record carries a header and nothing else), and
# a Work whose Solr document predates the OAIIndexer backfill. An empty
# <metadata/> would fail the XSD, which requires exactly one child.
xml.tag!('record') do
  xml << render('oai/header', record: record)
  next if record.deleted?

  body = prefix == 'mods' ? record.mods_xml : render('oai/dublin_core', dc: record.dublin_core || {})
  next if body.blank?

  # The MODS goes in verbatim: it is the preservation copy, and Atlas already
  # stores it rooted at <mods:mods> with a mods-3-5 schemaLocation, so it
  # needs no transform beyond dropping its XML declaration.
  xml.metadata { xml << body }
end
