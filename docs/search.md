# Search and gated Solr lists

The keyword search endpoint, and how Atlas decides which Solr documents a caller
may see in any list.

Source files:

- `app/queries/search_query.rb` — `GET /resources/search`
- `app/controllers/search_controller.rb` — its action
- `app/queries/concerns/solr_read_gate.rb` — the per-document read gate
- `app/queries/work_digest_query.rb` — Set contents and descendant works

## `GET /resources/search`

A text search for API clients such as Hyperion, the librarians' terminal client.
The response shape is in [`openapi.yaml`](../openapi/openapi.yaml). What the
schema cannot say follows.

**It is Cerberus's search bar without the Blacklight parts.** There are no facets,
no sort choice and no highlighting. The order is always
`score desc, created_at_dtsi desc, id asc`: Cerberus's relevance sort, then `id` so
a result cannot move between pages. With a blank `q` every document scores the
same, so a browse lists the newest first.

**The ranking comes from Solr, not from Atlas.** The query sets no `qf`, `pf` or
`mm`, so the `search` handler in `blacklight-solr`'s `solrconfig.xml` supplies them,
exactly as it does for Cerberus. **To make a field searchable, change `qf` there,
not here.** The handler's `qf` does not yet reach subjects, names or dates.

**Rows come off the Solr doc.** Nothing is loaded from Postgres, so the read path
costs one Solr request. `year` is `pub_date_ssim`, not `date_ssi`: that one is a
sort key in timestamp form and is never displayed.

### The filters copy Cerberus, and must change with it

Nothing checks that these stay in step with Cerberus's `SearchBuilder`, so each
one names its source there. The one intended difference is the read gate below.

| `fq` | Cerberus source | When |
|---|---|---|
| no FileSet, Blob or Delegate | `CatalogController` default `fq` | always |
| `-tombstoned_bsi:true` | the same | always |
| no featured Collection, personal root or system container | `SearchBuilder#exclude_curation_containers` | always; this is the global catalog |
| the read gate | `SearchBuilder#apply_gated_discovery`, widened | not for `:admin` |
| no unfinished deposit, unless the caller deposited it | `SearchBuilder#exclude_unfinished_deposits` | not for `:admin` or the staff group |
| `internal_resource_tesim:<type>` | `SearchBuilder#scope_to_resource_type` | only when `type` is given |

Embargoed items are not filtered, because Cerberus does not filter them. A row
carries `embargoed` so a client can say so.

**Compilations never appear.** A Set is an ActiveRecord row and is not in Solr.

### Who may call it

`can :read, :catalog` holds for every principal except `:anonymous`, including a
guest and a read-only token. That grant only opens the endpoint. **Which documents
come back is the read gate's decision, per document, inside the query.**

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
