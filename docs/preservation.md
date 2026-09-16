# The preservation-first principle

**Read this before any decision about storage, metadata serialization, or
persistence.** It is the architectural anchor the rest of these pages assume.

The DRS is at its heart a **preservation system**, not just an API.

## The governing constraint

If everyone involved in the project quits or gets hit by a bus, a new hire
should be able to look at the storage layer — MODS XML files and binary files on
disk, or in S3 — and reconstitute important Northeastern Works **without any of
the surrounding software.**

That is a test you can apply to a design, not a slogan. Ask it of any change:
could someone with disk access and no Atlas rebuild what matters?

## What is source and what is derived

| Layer | Status |
|---|---|
| MODS XML on disk | **Source of truth** |
| Binary files on disk | **Source of truth** |
| Atlas, the Rails app | Derived and disposable |
| Postgres | Derived and disposable |
| Solr | Derived and disposable |
| The JSON access copy of MODS | Derived and disposable |

**The derived layers can be rebuilt from the on-disk XML and binaries. The XML
and binaries cannot be rebuilt from them.** That asymmetry is the whole point.

MODS XML is the canonical preservation copy because it is a self-describing,
open, library-standard format that survives any change in tooling. A future
maintainer needs no Atlas-specific knowledge to read it.

## Three rules that follow

1. **The on-disk layout must stay self-describing and human-recoverable.** Do
   not bury content behind app-specific encoding, a proprietary format, or a
   schema only Atlas can decode.
2. **Preservation-relevant metadata belongs in MODS XML first**, and is
   projected into JSON for access — never the other way around.
3. **Treat Postgres and Solr as caches over the source of truth.** They are
   rebuildable; act accordingly.

## Where this shows up in the code

These are the places the principle is doing visible work, and the pages that
explain each:

| Concern | Page |
|---|---|
| XML preserves while JSON serves, and why no read path parses XML | [`mods.md`](mods.md) |
| The on-disk envelope that makes the graph and the ACLs recoverable | [`resource-graph.md`](resource-graph.md) |
| `handle` rides the envelope because nothing can re-derive it | [`handles.md`](handles.md) |
| `full_text` and `derivative_permissions` are omitted because they can be made again | [`resource-graph.md`](resource-graph.md) |
| Why a personal root's MODS gets a real title rather than `""` | [`people.md`](people.md) |

## The test that decides a new field

When you add a derived field, ask one question: **can this be regenerated from
the source of truth?**

- **Yes** — keep it in Postgres and Solr, and leave it out of the OCFL envelope.
  A thumbnail, an extracted full text, and a per-tier visibility policy are all
  in this group.
- **No** — it belongs in the envelope, and the envelope's schema version has to
  move with it. `handle` is the clearest case: an external Handle service holds
  the other half of the binding and the outside world cites it, so a rebuild
  that lost it would break every citation.

Getting that answer wrong in the cautious direction costs disk. Getting it wrong
in the other direction loses something permanently.
