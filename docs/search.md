# Search and gated Solr lists

How Atlas decides which Solr documents a caller may see in a list, and why that
rule is wider than a read-groups filter.

Source files:

- `app/queries/concerns/solr_read_gate.rb` — the per-document read gate
- `app/queries/work_digest_query.rb` — Set contents and descendant works

## The read gate

Every gated Solr list adds one `fq` from `SolrReadGate#read_gate_fq`. It admits a
document when any of these holds:

| Clause | Why |
|---|---|
| `read_access_group_ssim` is `public` or one of the caller's groups | the read list |
| `edit_access_group_ssim` is one of the caller's groups | edit implies read |
| `edit_access_person_ssim` is the caller's NUID | edit implies read |
| `depositor_ssi` is the caller's NUID | a depositor owns the item |

That is the same rule `Ability#resource_readable?` applies when the caller opens
one item. **A list must never hide an item its caller can open.**

### Why a read-groups filter is not enough

Solr stores the two ACL lists in separate fields; `AccessControlsIndexer` never
merges them. Every creator service adds the staff group as an **edit** group
only, and a personal root records its owner only as `depositor`. So a filter on
`read_access_group_ssim` alone hides every private item from the non-admin
librarians who edit it, and hides a depositor's own private Works from them.

Cerberus's `SearchBuilder#apply_gated_discovery` has that narrow filter, though
its own `Ability` says edit implies read. Until it widens too, an Atlas list shows
staff and depositors more than the matching Cerberus page. Every extra row is an
item they can already open.

### Who is exempt

**Only `:admin`.** `:system` can read any single resource through `Ability`, but a
list read as `:system` belongs to no person, so exempting it would hand private
Works to whatever the list feeds. A guest has no groups and no NUID, so the gate
reduces to `public`.

### Every value is a quoted phrase

Group names come from Grouper and can contain spaces. `RSolr.solr_escape` leaves
spaces bare, so a group named `a OR b` would become two clauses. The gate quotes
each value instead, escaping only `"` and `\`.

### What does not use it

`OaiWorksQuery` filters on `read_access_group_ssim:public` and nothing else,
because OAI-PMH is a public feed with no caller. See [`oai.md`](oai.md).
