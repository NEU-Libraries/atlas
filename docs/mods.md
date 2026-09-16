# MODS: the dual representation

Every Modsable resource stores its descriptive metadata twice, and which copy
you are looking at decides what you may do to it.

Source files:

- `app/models/concerns/modsable.rb` — keeps the two copies in step
- `app/models/metadata/mods.rb` — the JSON access copy
- `app/lib/mods_*.rb` — the conversion layer
- `app/services/mods_version_history.rb` — the per-version XML history

The display layer is [`mods-display.md`](mods-display.md). The browse-axis
vocabulary shared with the indexers is [`mods-browse.md`](mods-browse.md).

## XML preserves, JSON serves

| Copy | Where | Role |
|---|---|---|
| MODS XML | A `Blob` in a "descriptive metadata" `FileSet`, whose `descriptive_metadata_for` points back at the resource | **The preservation copy.** Self-describing, open, library-standard, and survives any change in tooling. |
| JSON | A `metadata_mods` row (`Metadata::MODS`, `attr_json`) | **The access copy.** Fast to read, easy to project into HTML or a downstream Wordpress. |

The XML is the source of truth. The JSON row, Postgres and Solr are rebuildable
caches over it — see the preservation-first principle in `CLAUDE.md`.

**The tradeoff is explicit: writes may be slow, reads must be fast.** `mods_xml=`
writes the blob *and* re-extracts the JSON through `mods_json=`, so a write pays
for both. In exchange, no read path parses XML.

**If you reach for Nokogiri in a controller or a decorator, that is the smell
this design exists to prevent.** Push extraction into the write path instead.

New preservation-relevant metadata therefore belongs in the XML first and is
projected into JSON for access, never the other way round.

## The access copy derives its attributes

`Metadata::MODS` does not restate its attribute list. It walks
`NEU::MODS::FIELDS` and declares one `attr_json` per field:

```ruby
NEU::MODS::FIELDS.each do |field, cardinality|
  attr_json field, TYPES.fetch(field, :string), array: cardinality == :many
end
```

**Restating the list is what let nineteen attributes sit declared but never
projected.** Nothing failed when the two drifted: the attribute stayed nil and
the display row silently did not render. Deriving makes that drift structurally
impossible rather than merely tested.

**Adding a field needs no migration.** `attr_json` attributes live in the
existing `json_attributes` jsonb column, which `mods_json=` assigns wholesale.

`TYPES` names only the fields whose value is not a plain string. Anything absent
is a `:string`, single or array according to its `FIELDS` cardinality.

### The four value shapes

| Constant | Projects as | Which fields |
|---|---|---|
| `LABELED_VALUE_FIELDS` | `{ value:, display_label:, href: }` | Every plain string field a record can re-head with `@displayLabel` |
| `AUTHORIZED_VALUE_FIELDS` | The above plus the term's vocabulary | `genres` only |
| `ORIGIN_VALUE_FIELDS` | The above plus the block's `@eventType` | Fields inside an `originInfo` block |
| `TYPES` entries | A structured `Metadata::Fields::*` type | `names`, `subject_headings`, `identifiers`, and the rest |

`genres` is the only authorized-value field because it is a browse axis, and a
consumer offering a link needs to know the term is controlled. Nothing gates on
the vocabulary of an extent, and three more keys across fourteen fields is JSON
no consumer reads.

### A date projects six fields

`date_created`, `date_issued` and `copyright_date` each project a value, an end
value and a key-date flag. The two values are `:datetime` because the sort key,
the citation year and the OAI date all need a real date object. The key-date flag
is the record nominating its own principal date, so it is a `:boolean` rather
than a string.

## Version history: XML only

`MODSVersionHistory` assembles a resource's edit history from the OCFL storage
layer. It is read-only and entirely derived: it mints no storage and mutates
nothing.

**Only the XML is version-recoverable.** Every descriptive-metadata edit appends
a new OCFL version of `descMetadata.xml`, whereas the JSON access copy is
overwritten in place by `Modsable#mods_json=`. So this object lists every version
and fetches any version's raw XML, but never JSON. A per-version JSON would have
to be re-derived from the historical XML, which is deliberately out of scope.

Two sources combine, and either may be absent:

- **OCFL** is authoritative for version labels and timestamps, through
  `find_version_metadata`. No MODS blob yet means an empty history.
- **The `AuditEvent` ledger** supplies actor attribution. No correlatable event
  means a null `actor_nuid`.

### Content-distinct states, not raw revisions

The descriptive-metadata Blob shares its NOID-keyed OCFL object with its own
preservation envelope (`properties.json`, `permissions.json`), and OCFL state is
cumulative. So an envelope rewrite — the backfill rake task, for instance — cuts
a new version that still carries `descMetadata.xml` at its prior, unchanged
digest.

Surfacing those byte-identical revisions as separate versions gives the diff
screen empty no-ops. `collapse_consecutive_identical` coalesces consecutive
identical digests and keeps the **earliest** of each run — the moment the content
became that state, which is also when its correlated edit event fired.

**Only consecutive runs collapse**, so a genuine A → B → A still yields three
versions.

### Attribution is timestamp proximity, and best-effort

The OCFL `user` field holds the app's user agent, not the editing NUID, so there
is no identifier to join on. Instead, `correlated_event` picks the closest
`metadata` `AuditEvent` within `CORRELATION_WINDOW` (5 seconds).

That window is generous on purpose. The metadata-edit event fires immediately
after the OCFL upload within the same request — `WorksController#binary_update`
calls `mods_xml=` then `audit!` — so `occurred_at` trails the version's `created`
by well under a second. The margin absorbs clock granularity and skew.

The seed version a Work is born with has no edit event, so it resolves to a null
actor.

Every `change_type: 'metadata'` event is a MODS-touching edit. Descriptive fields
are written only through the full-document `mods_xml=` upload; there are no flat
per-field setters on the metadata PATCH.

`mods_events` matches on `resource.id` rather than the NOID, because the writer
stamps `resource_id` with the Valkyrie UUID and the live resource is in hand here.

`fetch_xml` locates a version through `find_versions` rather than reconstructing
the per-version id by hand, so id construction stays the storage adapter's
concern.
