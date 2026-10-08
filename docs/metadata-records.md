# Additional metadata records

A Work always holds two XML metadata records: MODS (descriptive) and METS
(structural). It can also hold **additional records**, each in a dedicated
format. Darwin Core is the first. This page explains the recipe every format
follows, and then the choices specific to Darwin Core.

Source files:

- `app/models/concerns/metadata_records.rb` — the list of formats
- `app/models/concerns/metadata_records/darwin_core.rb` — the record on the Work
- `app/models/metadata/darwin_core.rb` — the JSON access copy
- `app/lib/darwin_core_document.rb` — the shape rules and the projection
- `app/controllers/darwin_core_controller.rb` — the endpoints
- `app/services/darwin_core_version_history.rb` — the version history

The endpoints are documented in `openapi/openapi.yaml` under
`/works/{id}/dwc` and `/resources/{id}/dwc`.

## One format, one concern

Each format gets its own concern, parser, table and endpoints. There is no
generic "any XML" record. A shared display would be too thin to be useful, and a
format that does not earn dedicated parsing should stay a plain file upload.
That already works: an uploaded `.xml` file is classified `structured_text`.

The concerns sit in the `MetadataRecords::` namespace rather than taking the
`-able` suffix, because the suffix stops reading well once format acronyms
appear. `Modsable` and `Metsable` keep their names.

`MetadataRecords::DarwinCore` is the behaviour on the Work. `Metadata::DarwinCore`
is the access-copy model. The two namespaces are distinct on purpose.

## The recipe

| Part | Darwin Core |
|---|---|
| Concern on `Work` | `MetadataRecords::DarwinCore` |
| Role on the Blob | `Role.darwin_core` |
| FileSet classification | `Classification.darwin_core` |
| OCFL filename | `dwc.xml` |
| JSON access copy | `Metadata::DarwinCore`, table `metadata_darwin_core` |
| Audit `source`, and token in `metadata_formats` | `dwc` |
| Document rule | exactly one `dwr:SimpleDarwinRecord` |

A new format adds a row to each of these, adds its token to
`MetadataRecords::SOURCES`, and chains its own `metadata_formats` through
`super` so the Work JSON lists every record it holds.

## Preservation: which side of the line

The XML in OCFL is the source. The `metadata_darwin_core` row is derived from it
and can be rebuilt from it. The record's Blob hangs off its own FileSet, beside
the descriptive and structural ones, so a reconstitution tool finds it by the
FileSet classification and the Blob's `use`.

The record is **not** placed in the descriptive-metadata FileSet.
`Modsable#mods_blob` takes that FileSet's first Blob, so a second Blob there
could be read as the MODS.

## Why the record is not content

`Classification.metadata?` includes `darwin_core`. That one predicate keeps the
record out of `FileSet#page?`, so it never reaches the METS structMap,
`/works/{id}/file_sets` or the Content facet. It also keeps the record out of
`/works/{id}/assets`. The download comes from the record's own endpoint instead.

## Lifecycle

**Lazy creation.** The FileSet and Blob are created on the first write, the way
`Work#create_mets_blob` does it. Existing Works need no backfill.

**Checked before written.** `DarwinCoreDocument` parses the upload before
anything is stored, so a refused document leaves no OCFL version behind.

**Withdrawal, not purge.** `DELETE /resources/{id}/dwc` tombstones the FileSet and
deletes the access-copy row. The OCFL object stays, and so does its version
history. The tombstone rides the FileSet's envelope, so a rebuild from disk
skips the record too. The next PUT restores the FileSet and appends a version to
the same Blob.

**The access copy decides presence.** The read endpoints and `metadata_formats`
ask one question, "is there a row?", which is a single indexed lookup. A
withdrawal deletes the row, so the read path never has to walk the Work's
children to find a tombstone.

## Audit and version history

Every write records `change_type: 'metadata'`, the same as a MODS write, with
`payload.source` set to the format's token. `AuditEvent::CHANGE_TYPES` is a
closed list, and `source` already tells MODS writes apart.

`MetadataVersionHistory` holds the version logic shared with MODS; see
[`mods.md`](mods.md#version-history-xml-only). `DarwinCoreVersionHistory`
correlates only `update` events with the `dwc` source. A withdrawal writes the
FileSet's envelope rather than the Blob, so it must not be matched to a Blob
version.

## Darwin Core shape rules

Atlas checks shape only. Validating against `tdwg_dwc_simple.xsd` happens in
Cerberus, before the upload reaches Atlas. Atlas keeps the shape rules so that a
caller that skips Cerberus cannot store a document the projection cannot read.

| Rule | 422 `error` |
|---|---|
| The document is well-formed XML | `malformed_xml` |
| The root is `dwr:SimpleDarwinRecordSet` | `invalid_root` |
| It holds exactly one `dwr:SimpleDarwinRecord` | `record_count` |
| No term appears twice | `duplicate_term` |

A Work describes one specimen, so its record holds one `SimpleDarwinRecord`.
Another format sets its own rule; VRA Core, for one, allows many records in a
document.

Simple Darwin Core allows each term once. The projection rejects a repeat rather
than keeping one value, because keeping one would drop data from the access copy
without anyone noticing. `dc:type` and `dcterms:type` count as a repeat, since
both project to the key `type`.

## The projection

Each `dwc:`, `dc:` and `dcterms:` element of the record becomes one key, named
by the term itself (`catalogNumber`, not `catalog_number`), because Cerberus
labels terms by name. Blank terms are left out. A term in any other namespace
stays in the preserved XML and is left out of the JSON.

The XML endpoint serves the stored bytes unchanged, not a reformatted copy,
because it is the standalone download.

## Not built

- **Solr projection.** No indexer reads the record. Projecting `scientificName`,
  `eventDate`, `country` and the coordinates would also need fields in the Solr
  image. Display does not need it.
- **A `dwc` OAI-PMH prefix.**
