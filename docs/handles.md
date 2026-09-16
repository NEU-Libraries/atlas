# Handles

Minting the persistent identifier for a finalized Work, and recording it in the
two places that have to agree.

Source files:

- `app/services/handle_minter.rb`
- `app/lib/handle_client.rb`

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

**Save order is load-bearing.** `mint` saves the resource first and writes MODS
second, so a document that refuses the write still leaves a minted Work behind.
The reverse order could register a handle on the external service and keep no
record of it here, **which nothing in the repository could re-derive.**

## The MODS write runs on every call, not only on a mint

A Work minted before this service existed, or one whose document was later
replaced wholesale through `mods_xml=`, holds the attribute and not the
identifier. **Running the reconciliation unconditionally is what heals both.**

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

`keep_existing?` refuses to overwrite in two cases.

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
second mint.

`handle_in` strips any host, because v1 wrote `http://hdl.handle.net` and a
deployment can resolve through its own proxy.

## A no-op write is skipped

`mods_with_identifier` returns nil when there is nothing to change. **Every write
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
