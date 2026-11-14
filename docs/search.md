# Search and gated Solr lists

The keyword search endpoint, and how Atlas decides which Solr documents a caller
may see in any list.

Source files:

- `app/queries/search_query.rb` — `GET /resources/search`
- `app/controllers/search_controller.rb` — its action
- `app/queries/concerns/solr_read_gate.rb` — the per-document read gate
- `app/queries/work_digest_query.rb` — Set contents, descendant works and the
  scoped search routes
- `app/queries/scoped_search.rb` and
  `app/controllers/concerns/scoped_search_params.rb` — the scoped search's
  keyword, filters, facets and sort
- `app/queries/search_explanation_query.rb`, `search_explanation_fields.rb`,
  `solr_field_analysis.rb` and `solr_schema.rb` — `GET /resources/:id/search_explanation`
- `app/controllers/search_explanations_controller.rb` — its action

## `GET /resources/search`

A text search for API clients such as Hyperion, the librarians' terminal client.
The response shape is in [`openapi.yaml`](../openapi/public/openapi.yaml). What the
schema cannot say follows.

**It is Cerberus's search bar without the Blacklight parts.** There are no facets,
no sort choice and no highlighting. The order is always
`score desc, created_at_dtsi desc, id asc`: Cerberus's relevance sort, then `id` so
a result cannot move between pages. With a blank `q` every document scores the
same, so a browse lists the newest first.

**The ranking comes from Solr, not from Atlas.** The query sets no `qf`, `pf` or
`mm`, so the `search` handler in `blacklight-solr`'s `solrconfig.xml` supplies them,
exactly as it does for Cerberus. **To make a field searchable, change `qf` there,
not here.** The handler's `qf` does not yet reach dates.

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
carries `embargoed` so a client can say so. An embargoed Work's full text is not
in the index at all, so a body-text query cannot match it until the embargo
lapses; see [`authorization.md`](authorization.md#what-else-an-embargo-withholds). The flag is computed at read time
from `embargo_release_date_dtsi`, not stored in Solr: a stored flag would stay
`true` after the release date, because nothing re-indexes a Work on that day
except the nightly release sweep, which may run hours later.
An embargo lifts at the start of its release date in Eastern time, which is how
Cerberus reads the date.

**Compilations never appear.** A Set is an ActiveRecord row and is not in Solr.

### Who may call it

`can :read, :catalog` holds for every principal except `:anonymous`, including a
guest and a read-only token. That grant only opens the endpoint. **Which documents
come back is the read gate's decision, per document, inside the query.**

## Searching within a scope

`GET /compilations/:id/search`, `GET /collections/:id/search` and
`GET /communities/:id/search` search the Works of one Set, or the Works and
Collections of one container's whole subtree. They exist for CERES, the WordPress
plugin that shows DRS items on library sites, and replace v1's
`/api/v1/search/:id`. The parameters and the response are in
[`openapi.yaml`](../openapi/public/openapi.yaml). What the schema cannot say
follows.

**They are `/contents` and `/descendant_works` with a search on top.** The same
`WorkDigestQuery` resolves the scope, with the membership clauses in `fq` and the
read gate below. A `ScopedSearch` adds `q`, the filters, the facets and the sort.
The scope is checked first, as on the typed `children` routes: a Set the caller
may not read answers `403`, an id of the wrong type answers `404`, and a
tombstoned container answers `410`.

**The container routes return Collections too, because v1 did.** v1's scope
clause named each descendant Collection by its own id, and no filter dropped the
model, so a Collection was a hit beside the Works. The two container routes keep
that: they add every Collection whose `ancestor_ids_ssim` holds the scope, so the
scope itself is never a row. The Collections get the read gate and the tombstone
filter the Works get, and lose the featured, personal-root and system containers
the global catalog drops. A row tells the two apart by `klass`. The Set route
stays Works only: a Set's Collections are a recipe for its Works, not items in
it. `/descendant_works` stays Works only too; the search routes ask for the
Collections with `DescendantWorksQuery`'s `include_collections`.

A Collection carries none of the Work values the filters match, so any `f` drops
every Collection. It has no created date either, so `sort=date` puts the
Collections last.

**They hide three states from every caller, admins included.** CERES is a public
feed, so these routes drop each Work that is embargoed
(`-embargo_release_date_dtsi:[NOW TO *]`), in progress (`-in_progress_bsi:true`)
or incomplete (`-incomplete_bsi:true`). `/contents`, `/descendant_works` and
`/resources/search` do not, so the same Work can appear there and not here. The
three filters are separate `fq` lines. v1 joined them with `OR`, and Lucene
reads every clause of such a line as MUST_NOT, so it ran as an AND anyway. An
exemption for curators can come later, if a client needs one.

**Only the allowlisted fields can be faceted or filtered.** A facet count shows
values the digest never carries. Faceting on `depositor_ssi` would list NUIDs,
and faceting on the ACL fields would list who holds access. A filter on such a
field can probe a value through the count it returns. So `facet[]` and the keys
of `f` take only `ScopedSearch::FACET_FIELDS`, and any other field answers
`400`. **The list copies the facets in Cerberus's `CatalogController`, and the
two must change together.** A field CERES needs that Cerberus does not facet on
needs an indexer change first.

**Filter values match exactly.** Each value is a quoted phrase against a string
field, quoted as the read gate quotes its values. Values in one field are joined
with `OR`, and each field is its own `fq`, so the fields are joined with `AND`.

**The facet counts cover the whole result.** They count every matching row in
the scope after the filters, not just the page. A field's own filter narrows its
counts too: filter on one genre and `genre_ssim` counts only that genre. Values
come most frequent first, with zero counts dropped, up to `facet_limit` (20 by
default, at most 100). v1 sent no limit, which the routes do not allow, because a
creator facet over a large Community can run to thousands of values.

**The sorts are named.** `relevance` is `score desc, id asc`, `title` sorts on
`title_ssi`, and `date` sorts on `date_ssi`, newest first. With no `sort`, a
query with `q` sorts by relevance and one without sorts by `id`, as `/contents`
does. Solr sort syntax is never taken from the caller.

## Explaining one object: `GET /resources/:id/search_explanation`

Solr's own account of how the catalog search scores one Work, Collection or
Community for some words, whether it matches or not. It answers "why does this
record not come up for these words?" and "why does it rank where it does?". The
response shape is in [`openapi.yaml`](../openapi/internal/openapi.yaml).

**Atlas gathers; the client interprets.** Atlas chooses the Solr requests and
groups what they return. It does not label fields, total points or write
sentences. Hyperion parses the tree, as Cerberus's `SearchExplanation` does.

### `explainOther`, not a narrowed search

Cerberus's "Why this result?" reruns the search narrowed to the result, so the
result always matches. Debugging more often asks why something does **not**
match, and then a narrowed search returns nothing to explain. `explainOther`
explains the named document either way, in one tree shape with a `match` flag.

### The Solr requests

| Request | What it gives |
|---|---|
| `select` with the words, `debug`, `explainOther` and `echoParams=all` | The tree, the parsed query, the handler's `qf`, `pf`, `mm`, `tie` and `boost`, and the full-text highlight |
| `select` with `q=*:*` and one `facet.query` per catalog filter | The stored text, and `hidden_by`: a filter whose count is 0 hides the object |
| `analysis/field`, one per stored value, sent eight at a time | Each value's index tokens, with `match` set, for every searched field it feeds |
| `analysis/field` with no value | The query's tokens in every searched field, as typed and as analysed |

None of them adds a read gate. The endpoint has already authorized `:read` on the
object, and a filter never changes a score.

**The ranking and the field map come from Solr, not from Atlas.** `qf` and `pf`
are read from the handler's echoed parameters on every call, so the explanation
follows `solrconfig.xml`. Which stored fields feed a searched field comes from the
schema API's `copyFields`, and whether a field is stored comes from its definition
there. `SolrSchema` reads that once per process, so **restart Atlas after a Solr
schema change.**

**The catalog filters are `SearchQuery::CATALOG_FILTERS`,** one definition for
the search and for `hidden_by`. The unfinished-deposit rule and the read gate are
not in it: they depend on the caller, and admins and staff are exempt from both.

### Which text is analysed

A searched field takes its text from itself when stored, and from each named
`copyField` source. Wildcard sources are skipped; they feed only `all_text_timv`,
which the handler does not search. A field with nothing to analyse says why:

| `reason` | Meaning |
|---|---|
| `not_stored` | Nothing stored feeds the field. `name_variant_teim` is the case today: `NameVariantIndexer` computes it |
| `full_text` | `full_text_tesimv` is stored but too long to analyse. `highlights` holds the passages that matched |
| `not_in_schema` | `qf` names a field the schema does not define, so it can never match |
| `analysis_failed` | An analysis request failed. The other fields are still returned |

Every `qf` field is reported, not only the ones that scored. A field that should
have matched and did not is the point of the tool.

**Each source is capped at 25 values,** and `truncated` says when one was cut. A
typical Work has fewer than 30 stored values across these fields.

**Offsets are Solr's,** counted in UTF-16 code units. Atlas passes them through,
and the client converts them.

### Who may call it

The same gate as `GET /resources/:id/solr`: `:read_index` on the type, then
`:read` on the object. See [`solr-indexing.md`](solr-indexing.md#who-may-call-it).
People are searchable but out of scope, so a Person answers 404, as a Set does.

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
