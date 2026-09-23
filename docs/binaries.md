# Binaries

The Blob API: versioning, rollback, fixity, byte-serving, and how attribution is
correlated back to a revision.

Source files:

- `app/controllers/blobs_controller.rb` — the whole binary surface
- `app/services/binary_version_history.rb` — the revision list
- `app/services/file_event_ledger.rb` — attribution lookup
- `app/services/storage_root_sealer.rb` — deciding a root is full

The storage adapter itself is `app/lib/valkyrie/storage/ocfl.rb`.

## `file_identifiers` is the authoritative revision list

This is the single fact the version history is built on. `BlobCreator` seeds the
first entry, and **every `PATCH /files/:id` and `POST /files/:id/rollback`
appends exactly one.** Each entry is the versioned OCFL id (`…/vN/<logical-path>`)
of the bytes written for that revision.

**So the listing reads straight off that array — no OCFL version scan, and no
digest coalescing.**

That is the difference from `MODSVersionHistory`, which *has* to collapse
byte-identical runs because it cannot tell a descMetadata edit from an
envelope-only bump carrying the same bytes forward. Here the Blob already records
precisely which OCFL versions were content writes, so:

- Envelope bumps (`properties.json`, `permissions.json`) never appear.
- A genuine re-upload of identical bytes **is** still its own listed revision.

See [`mods.md`](mods.md) for the other side of that contrast.

### The revision ordinal is contiguous

The 1-based position in `file_identifiers` **is** the content-revision number,
with revision 1 the seed. It never skips the way the OCFL `vN` label does,
because envelope bumps consume `vN`s and `file_identifiers` holds only content
writes.

The code numbers forward, then reverses to present newest-first.

### Only listed revisions are addressable

`find_file` resolves through `file_identifiers`, **so an envelope-only version
label never resolves.** You can only retrieve bytes the listing surfaced.

## Attribution is matched exactly, not by proximity

A `replace_file` event stamps the exact version id it produced, so subsequent
revisions match by id. The seed revision is the one `add_file` recorded for this
Blob.

**Unlike the MODS timestamp-proximity correlation, there is no window to tune.**

Either event may be absent — a migrated or back-loaded Blob has no
controller-sourced event — in which case attribution is null.

### File events hang off the parent Work

`AuditEvent::RESOURCE_TYPES` admits neither Blob nor FileSet, so there is no
per-Blob audit row. A Blob's rows are found by walking Blob → FileSet → Work and
then filtering that Work's ledger by blob NOID.

**The walk is what costs:** two graph reads plus a ledger read for every Blob.

`FileEventLedger.for_blobs` takes both hops through the batched parent query and
reads every Work's ledger in one `AuditEvent` query, so attribution for a whole
batch costs a fixed number of queries. `for_blob` is the same code path for one
Blob.

An orphan Blob with no resolvable parent Work gets empty attribution rather than
an error.

## `version_facts` must key on the full identifier

This is the subtle one. Each identifier carries **both** its version and its
logical path, and both matter: **a replace writes the bytes under the uploaded
file's name, so a revision's logical path need not be the current one.**

Asking the inventory only for the versions holding the *current* path therefore
answers nothing for the superseded revisions — **which is how a fixity column
empties out as soon as a version stops being head.**

`version_label` asks the adapter rather than re-parsing the id string, because
the adapter owns the id grammar.

Fixity is read from the inventory **without re-hashing**, and rendered as a
self-describing `<algorithm>:<hexvalue>` — the same shape as the Blob's
denormalized head `digest`.

## Why the batch endpoint exists

**Attribution is what makes batching worth it.** The admin file-manage listing
reads every replaceable Blob on a Work, which on a multipage Work is one request
per page binary.

The OCFL inventory reads stay per-object, because each Blob is its own OCFL
object and there is nothing to fold.

## Rollback is non-destructive

`POST /files/:id/rollback` promotes a prior version by **appending its bytes
again as a new revision.** vN's bytes become vN+1, and the Blob NOID is
preserved.

**OCFL dedups the identical content, so no bytes are copied** — only a new
version pointer is cut.

`rolled_back_from` records which version a revision reinstated.

## Head facts are a read-path cache, and must be re-derived

`digest`, `size` and `mime_type` describe the bytes that are **currently** head,
so a new revision re-derives all three.

**A stale `size` is what a consumer sets `Content-Length` and its Range
arithmetic from — a replaced audio file would truncate mid-stream.**

### The MIME hint is the deposited filename, not the upload's

Marcel needs a real extension for formats with weak magic bytes. **A staged temp
path like `up.tmp` makes it answer `application/octet-stream` where `data.csv`
answers `text/csv`.**

Magic bytes still win over the hint, so a genuine format change is still
detected.

### Three fields stay as deposited

`original_filename`, `use` and `label`.

**`label` especially: re-deriving it from bytes would relabel any replaced
derivative tier** — Small Image, Medium Image — back to Master Image.

## The version endpoints are admin-gated, but by a narrow verb

`versions` and `find_many_versions` expose edit attribution, so they are gated
like the MODS version list — **through the dedicated `:read_versions` verb
rather than the generic `:read, AuditEvent`.**

That lets the devolved-admin tier see binary history **without also opening the
generic audit-history index.** See [`authorization.md`](authorization.md).

`:read_versions` is granted class-wide, so there is no per-Blob decision and
nothing is dropped for authorization in the batch case.

### Two different 404 temperaments

| Endpoint | An unresolvable id |
|---|---|
| `GET /files/:id/versions` | **404.** A Blob is a concrete resource. |
| `POST /files/find_many_versions` | **Dropped.** Tolerant like `resources#find_many`, so the result may be shorter than the input. Callers index by `blob_id`. |

An id resolving to a resource that is not a Blob is dropped too.

## Byte-serving

`send_file` hands a `Pathname` to `Rack::Files`, which chunks at the Rack layer,
**so this is memory-safe for 20GB-plus files.**

### Range support exists so media elements can seek

A browser media element issues `Range: bytes=…` and expects a `206 Partial
Content` it can scrub over.

| Condition | Response |
|---|---|
| Always | `Accept-Ranges: bytes` |
| No Range, or an unparseable one | `200` with the whole body |
| A satisfiable single range | `206` plus `Content-Range` |
| Syntactically valid but out of bounds | `416` |

**Multi-range is unsupported** — a single range is all media elements need. RFC
7233 permits ignoring a Range you do not understand and serving the full 200,
which is what an unparseable header and a multi-range header both get.

The slice is streamed in chunks through `FileSlice`, never buffered.

**Once nginx fronts Atlas**, un-comment the `X-Accel-Redirect` line in
`config/environments/production.rb` so nginx handles byte-serving, and Range,
natively.

## `GET /files/:id/ancestry`

Resolves a content Blob to its parent FileSet and Work NOIDs.

**The download path is keyed only by the blob id**, so a consumer recording a
download impression against the containing Work resolves it here rather than
threading the Work NOID through the download URL.

It reads on the Blob floor, like `content` and `show`. Either ancestor is null
when unresolvable.

## Sealing a full storage root

**The adapter deliberately never measures a root.** It reads a seal marker and
obeys it, so the write path costs one existence check. Deciding means counting,
which is cold, and that is what `StorageRootSealer` is for.

### It counts objects, not bytes

An object count is three levels of `readdir` under the tuple layout, while a byte
total needs a full recursive walk. **And a root large enough to be worth sealing
is exactly the one that walk is too expensive for.**

### What `DEFAULT_MAX_OBJECTS` means

An object is one Atlas resource, so **a Modsable container costs three and each
deposited file costs three — a single-file Work is six.**

And an object is not a stored file: this content averages about thirteen files
per object, most of them inventory bookkeeping. **So two million objects is
roughly twenty-six million files.**

Raise it against a key budget for the destination rather than by feel.
