# Read-path performance

The design tradeoff Atlas makes is that writes may be slow so long as reads are
fast. This page covers the two mechanisms that keep the read side fast: batched
membership queries, and a response cache.

Source files:

- `app/controllers/concerns/cached_responses.rb` — the response cache
- `app/queries/find_many_members.rb` — children of many parents
- `app/queries/find_many_parents.rb` — the parent of many children
- `app/queries/find_many_by_alternate_identifiers.rb` — batch NOID resolution
- `app/queries/page_assets_query.rb` — two containment levels, two queries
- `app/queries/concerns/solr_refs.rb` — the Solr membership vocabulary

## The response cache cannot become an authorization bypass

**The shape is the whole point.** The action resolves its record and calls
`authorize!` *first*, then wraps only the render:

```ruby
def show
  work = find_work(params[:id])
  authorize! :read, work || Work
  return head(:not_found) if work.nil?

  cached_render('works.show', work) do
    @work = work.decorate
    render :show, status: (@work.tombstoned ? :gone : :ok)
  end
end
```

So a cached body is never handed to a caller the current ACL refuses. **An
outermost Rack cache layer would be an authorization bypass**, because that layer
never reaches `Ability` at all.

### What gets cached

`CACHEABLE_STATUSES` is `[200, 410]`. **410 is as stable as 200** — a tombstoned
resource keeps answering `gone` with the same body until something writes to it,
and that write evicts.

**Misses are not cached.** An unknown NOID never reaches `cached_render` because
the action 404s above it, and a body is only stored when the action actually
rendered one.

Every response carries an `X-Atlas-Cache` header of `hit` or `miss`.

### The one axis a cached view varies on

`works/_asset.json.jbuilder` withholds the `permission` group list from guests,
**so public traffic is never told a Grouper group's name.** `asset_audience`
mirrors that condition exactly.

**If the view's condition changes, `asset_audience` must change with it.** The
paired spec asserts the two buckets stay distinct.

### `format_scope` returns nil for an unenumerated format

`cached_render` then renders without caching. That distinction is deliberate: a
nil is a runtime input Atlas does not control — the request's format — whereas **a
scope string that is simply wrong is programmer error** and still raises in
`ResponseCache.key`.

## Containment is recorded from both ends

This is the fact every batching query is shaped around. `Relationships#children`
and `#parent` each read two directions, so a batched equivalent has to read both
too, in the same precedence order.

| Direction | Stored on | How it is queried |
|---|---|---|
| `a_member_of` | The child | The same `metadata @> ?` containment predicate `find_inverse_references_by` builds |
| `member_ids` | The parent | A lateral join over `jsonb_array_elements`, widened to a set of parents |

**Every disjunct is the exact predicate the unbatched read uses, so every term
hits the `jsonb_path_ops` GIN index on `orm_resources.metadata`.**

**Ids ride as bind parameters and are never interpolated.** Only the placeholder
*count* is built from input.

All three custom queries are Postgres-specific by construction, registered
solely against the postgres-backed query service both composite adapters read
through. They are wired up in `config/initializers/valkyrie.rb` and reached as
`Atlas.query.custom_queries.*`.

`run_query` is private on the postgres query service, so each custom-query
handler reimplements it — the pattern the Valkyrie docs' figgy example follows.

`id_type` is read off the column rather than hardcoded, matching how Valkyrie
builds the same cast in its own member queries.

## `FindManyMembers` answers two named queries

Keeping them apart matters, and this is the trap in the file:

| Query | Replaces | Reads |
|---|---|---|
| `find_many_members` | `children` | Both directions, inverse first |
| `find_many_ordered_members` | `find_members` | `member_ids` only, in stored order |

**Page order comes off `member_ids`, and the union puts the inverse direction
first — so conflating the two would reorder a Work's pages.**

Child order in `find_many_members` matches `Relationships#children` exactly, so a
preloaded read sees what an unbatched one would.

**Parents with no children are absent from the result, not empty.** Callers
default. The same holds for `FindManyParents`: a child with no resolvable parent
is absent rather than nil.

The parent id is selected alongside `member.*` **under an alias**, so it survives
into the ORM row without shadowing the member's own `id` column.

The `a_member_of` edge is scalar on the backbone — Collection, Work — and plural
elsewhere, so it is read as an array either way.

## `FindManyParents` resolves in precedence order

`forward_parents` runs first, because the edge is stored on the child and the ids
are already in hand. `inverse_parents` then covers only the children that
forward resolution missed.

**The inverse direction is the only one a Blob has.** Blobs declare no
`a_member_of`; their linkage lives in the parent FileSet's `member_ids`.

A child naming several `a_member_of` ids answers **the first that resolves**,
matching `Relationships#parent`'s `.first`.

## `PageAssetsQuery` flattens two containment levels

A page's assets are its own member Blobs plus the members of any nested
`:derivative` FileSet, where per-page IIIF Delegates land. The page's METS Blob
is excluded by `Role.downloadable?`.

**That is two levels of containment, so resolving it per page cost two queries
per page — a book-length Work paid hundreds.** Each level is now one batched
read, so the cost is fixed at two regardless of page count.

Member order is preserved within each level, because page order and asset order
both come off `member_ids`.

## `SolrRefs`: the uuid hop, in one place

Valkyrie's join fields (`a_member_of_ssi`, `a_linked_member_of_ssim`) store
`id-<uuid>`, while the API and the recipe tables speak NOIDs.

Doing that resolution in one place keeps the two consumers — `WorkDigestQuery`'s
gated digest engine and the OAI provider's cursor-paged feed — **from drifting
apart on what "member of this container" means.**

`container_refs` unions two lookups, because `ancestor_ids_ssim` speaks raw NOIDs
and carries **descendants only**. The roots are added explicitly through
`alternate_ids_ssim`. A NOID that no longer resolves simply matches nothing.

`CONTAINER_ROWS` is 10,000, matching `DescendantCollectionsQuery::ROWS`.
Branching lives among the roughly three thousand collections, and **works never
appear here**, so that bound covers the fan-out.

## Benchmarking honestly

A cached read measures the cache, not the query. When timing a change to any of
the queries above, clear the response cache first, or you are measuring
`ResponseCache.read` and nothing else.
