# Handles

Minting the persistent identifier for a finalized Work, and recording it in the
two places that have to agree.

Source files:

- `app/services/handle_minter.rb`
- `app/lib/handle_in_mods.rb`, the identifier rule both writers share
- `Work#replace_mods_xml`, for a whole-document MODS write
- `app/lib/handle_client.rb`
- `app/lib/handle_identifier.rb`
- `app/services/work_creator.rb`, for a supplied handle

## The handle is `<prefix>/<noid>`

Reusing the NOID as the suffix makes the handle deterministic and trivially
correlated to the object, **so no separate suffix counter has to be kept or
preserved.** That matters for a preservation system: a counter is state that
could be lost.

## Atlas writes the identifier, not the depositing client

Atlas is the only party that knows the handle at the moment it exists, and
`/complete` is the one choke point every deposit path crosses.

A client-side merge would have to be repeated per path and would skip any
depositor that is not Cerberus, **which drifts the preservation copy by
depositor.**

This does not reopen descriptive merges — those stay with the caller. Atlas fills
a slot it generated the value for, as it does for METS.

## Two records, two different failure policies

| Write | Policy | Why |
|---|---|---|
| The external handle server | **Best-effort.** Logged and swallowed. | `/complete` is load-bearing in DRS: re-finalization is routine and a bulk deposit leans on it, so a handle server that is down, slow or misconfigured must not fail a finalize. The Work stays unminted for a later `/complete` to pick up. |
| The MODS `hdl` identifier | **Raises.** | It is local, so it earns no such licence. It fails like the METS rebuild beside it in `/complete`. |
| The Work's preservation envelope | **Raises.** | Local, like the MODS write. It is the handle's only record on disk, so a rebuild from disk without it loses the binding every outside citation rests on. |

**Save order is load-bearing.** `mint` saves the resource first, then rewrites
its envelope, and writes MODS last, so a document that refuses the write still leaves a minted Work behind.
The reverse order could register a handle on the external service and keep no
record of it here, **which nothing in the repository could re-derive.**

## The MODS write runs on every call, not only on a mint

A Work minted before this service existed holds the attribute and not the
identifier. **Running the reconciliation unconditionally is what heals it.**

## A whole-document MODS write keeps the identifier

`PUT /resources/{id}/mods` stores a document the caller assembled, and three
Cerberus paths send one: the metadata forms, the XML editor and the XML loader.
A document that leaves the identifier out would drop it, and the minter adds it
back only when it runs again, at `/complete`, which a finished Work may never
reach. The loader drops it with no race at all, whenever its document was built
without one. The XML editor can drop it by holding a document read before
`/complete` minted.

So the PUT calls `replace_mods_xml`, and on a Work with a handle that applies
the same rule the minter does (`HandleInMODS`) before the document is stored:
an absent identifier is added, a bare handle becomes the resolver URL, and an
identifier naming a different handle is kept.

- **The handle is read again under the `mods` lock**, not taken from the copy
  the request loaded. `mint` saves the handle before it takes that lock, so
  either the PUT sees the new handle, or the minter's own MODS write comes after
  the PUT and adds it.
- **The stored document can differ from the upload.** The audit row records no
  XML, so it is unaffected.
- **The identifier cannot be removed through a PUT** while the Work holds a
  handle, and the handle is set at create only. A permanent identifier the
  preservation copy stops citing would be the loss this rule exists to prevent.

Collections and Communities hold no handle, so their documents are stored as
sent.

## Idempotent twice over

1. `call` skips a Work that already carries a handle.
2. The underlying PUT is keyed by handle name, so even a re-mint re-points an
   existing record rather than duplicating it.

## Why MODS and not the attribute alone

The resource attribute reaches the API and the Work page. MODS is what DRS
exports, versions, hands to the XML editor and serves over OAI-PMH, **so an
identifier absent from it is absent from all of those.**

neu-mods projects the node onto `Metadata::MODS#permanent_url`, so the JSON
access copy fills from the same write rather than needing a derived value of its
own.

## The identifier carries the resolver URL, not the bare handle

Three reasons:

1. It is the shape v1's records hold.
2. The field neu-mods projects it onto is named `permanent_url`.
3. A bare handle renders as dead text wherever the value is linkified.

Storing the bare form would also leave migrated and new Works holding two
different shapes in one field.

**`work.handle` stays bare.** That attribute is the identifier; the URL is the
citable form of it.

`DEFAULT_RESOLVER_BASE` is `https://hdl.handle.net`, the global proxy every
registered prefix resolves through. A dev stack homes an unregistered prefix,
which is in no Global Handle Registry and so cannot be answered for there, and
overrides the base with its own server.

`target_url` is where the handle sends a reader — the public Work page. **Cerberus
knows its own host and Atlas does not**, so the base arrives as config.

## When the document's identifier is left alone

`HandleInMODS#keep_existing?` refuses to overwrite in two cases.

**It already resolves this handle**, whatever host it names. A migrated record's
own resolver is therefore not rewritten. Only a bare handle is replaced, which
heals a document written before the URL shape.

**It names a different handle.** That means a v1 record migrated in under prefix
2047 whose `handle` attribute was never set, so this service minted a second
identifier. Both values are true — the v1 handle still resolves — and **a
preservation copy does not get to discard a true statement.** The document keeps
what it has, and the disagreement is logged.

**Adoption is deliberately not the answer.** Reading an identity back out of a
document any caller can assemble would spread one fixture's handle across every
Work built from it. The migrator setting `handle` on ingest is what stops the
second mint — see the next section.

`HandleIdentifier.bare` strips any host, because v1 wrote `http://hdl.handle.net` and a
deployment can resolve through its own proxy.

## A Work can bring its own handle

A migrated v1 Work already has a registered handle, and published citations rest
on it. `POST /works` therefore takes an optional `handle`. Atlas records it on
the Work with `handle_source: "supplied"`, and `/complete` then mints nothing,
because `call` skips a Work that already carries a handle.

**Atlas never re-points a supplied handle.** A mint is "create or re-point" on
the handle server, so a rehearsal that re-pointed v1 handles would send live
citations to a non-production host. Re-pointing them is a cutover decision. It
is also unneeded: v2 takes over the v1 hostname, and Cerberus redirects the old
URLs. Any future re-point path must skip a Work whose `handle_source` is
`supplied`. A handle minted here is `minted`, and a handle with no source
predates the field and was minted.

A repository reset follows the same rule. It deletes the handles Atlas minted
and never sends a request for a supplied one
([`availability.md`](availability.md#why-the-minted-handles-are-deleted)).

The rules for the write:

| Rule | Why |
|---|---|
| Admins and devolved admins only (`:supply_handle`), else `403` before anything is created | A handle is an identity claim, like an association ([`authorization.md`](authorization.md)) |
| `<prefix>/<suffix>` only, after `HandleIdentifier.bare` strips a resolver host; else `422 invalid_handle` | The same rule `keep_existing?` reads a document's identifier with |
| Unique across live and tombstoned Works; else `409 handle_taken` | A minted handle embeds the NOID and cannot collide, but a supplied one can. A tombstoned Work's handle still resolves |
| No call to the handle server | A rehearsal environment may not reach it, and a create must not depend on it |
| Set at create only | A later change would invite a re-mint or a silent change of identity |

**The uniqueness check runs under a Postgres advisory lock** keyed on the
handle, so two concurrent creates with the same handle cannot both pass it. The
lock is per session rather than a transaction, because the create also writes
Solr and OCFL, which no rollback could undo.

The handle goes on the Work's first save, and `handle_source` rides the envelope
(schema v9, see [`resource-graph.md`](resource-graph.md)). An idempotent replay
returns the original Work before any parameter is read, so a replay cannot
change the handle.

## A no-op write is skipped

`HandleInMODS#call` returns nil when there is nothing to change. **Every write
appends an OCFL version to the descriptive metadata**, so an unconditional write
would cut a version that says nothing new. See [`mods.md`](mods.md).

## The identifier node is created when absent

The MODS template ships an `hdl` identifier, but a caller-assembled document —
the XML editor, the loaders — need not. MODS 3-5 puts no order on top-level
elements, **so appending is safe.**

## Two things that are logged rather than raised

**A minted Work with no descriptive-metadata FileSet is malformed** — every
creator makes one. `log_unwritable` says so rather than raising, because failing
a finalize over a document that was already broken before this ran helps nobody.

**No server configured, or nowhere to point a handle at, means this deployment
does not mint.** That is the normal state for a test run and for any stack
brought up without the handles profile.

## `reload` mirrors `WorkMETSRebuilder`

The caller's copy is stale by this point in `/complete`, because the METS rebuild
wrote through the persister.

## Both writes retry a lock conflict

The two writes after the mint each retry with a reload, through `StaleRetry.run`
([`write-safety.md`](write-safety.md)).

**The Work save retries because the handle is live by then.** The handle
server's `PUT` has registered it, so losing the save would leave a handle that
resolves to the Work while the Work records none. Losing is likely during a
deposit, because every Delegate write and every full-text PATCH saves the Work.
The retry reloads the Work and keeps any handle it finds there.

**The MODS write retries because a MODS upload can race it.** The retry reads
the document again before it adds the identifier, so the upload's edit survives.

A conflict that outlasts both retries still raises. A second `complete` heals
it: the handle server's `PUT` overwrites the same handle, and the MODS write
runs on every call.
