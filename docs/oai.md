# OAI-PMH

The harvest endpoint at `/oai`: what it disseminates, how it pages, and what it
declares about itself.

Source files:

- `app/services/oai.rb` — the shared vocabulary and identifier scheme
- `app/services/oai/request.rb` — argument validation
- `app/services/oai/resumption_token.rb` — the stateless cursor
- `app/services/oai/dublin_core.rb` — the `oai_dc` crosswalk
- `app/queries/oai_works_query.rb` — one page, straight off Solr
- `app/controllers/oai_controller.rb` — the verb handlers
- `app/views/oai/` — the response bodies

The specs validate responses against vendored schemas, so a shape change fails
rather than drifting.

## `mods` is the format that matters

Boston Public Library consumes it for Digital Commonwealth. `oai_dc` ships
because the protocol requires every repository to support it, and it is a
documented crosswalk off the JSON access copy.

## What the provider declares

| Setting | Value | Why |
|---|---|---|
| `deletedRecord` | `transient` | Withdrawn records come back as `<header status="deleted">`, but a purged one leaves no Solr document at all. So this repository cannot promise a harvester that every deletion is reported, and `transient` is the honest declaration. |
| `granularity` | `YYYY-MM-DDThh:mm:ssZ` | The finest accepted and advertised. A repository advertising seconds must also accept `YYYY-MM-DD`, and `OAI::Request` does. |
| `baseURL` | Per deployment, from `config_for(:oai)` | v1's single worst defect was an `Identify` advertising the site root instead of the endpoint. **A harvester that trusts `baseURL` follows it and finds nothing.** |
| `SAMPLE_NOID` | `cj82kf90c` | `Identify` advertises the *shape* of an identifier, so this is illustrative rather than live. |

## Identifiers are `oai:<repositoryIdentifier>:<noid>`

`noid_from` returns nil for an identifier that does not belong to this
repository, and the caller answers nil with `idDoesNotExist`.

**The cut-over needs a full re-harvest rather than an incremental one**, because
v1 emitted `/neu:329563` — not a URI at all, since its `record_prefix` was empty.

## The resumption token is signed, and that is not decoration

The token is base64url JSON with an HMAC-SHA256 signature.

**It carries a Solr `cursorMark` and a set NOID that flow straight into a query**,
so an altered or truncated token must come back as `badResumptionToken` — never a
500, and never an injected filter clause.

`FIELDS` freezes `metadataPrefix`, `from`, `until` and `set` at the first
request. **OAI-PMH forbids a harvester from changing them mid-list, and
re-reading them from the token is what enforces that.**

Three implementation choices:

- **base64url with no padding**, rather than
  `ActiveSupport::MessageVerifier`'s standard base64. A `+` in a query string
  decodes to a space, and a `resumptionToken` travels as a query argument.
- **The key is derived** through `key_generator`, not the raw
  `secret_key_base`, so this token's key is not the key any other Rails
  subsystem signs with.
- **The token is stateless** — there is no server-side cursor table — so a
  harvester may resume a list at any time. `expirationDate` is therefore not
  advertised.

`decode` raises `InvalidToken` for a wrong shape, a bad signature, or a body that
is not a JSON object. The caller turns that into `badResumptionToken`.

## Paging: `cursorMark`, not `start`/`rows`

`cursorMark` holds its cost flat however deep a harvester walks, where
`start`/`rows` degrades on a large repository.

It needs a total sort order, which `oai_datestamp_dtsi asc, id asc` gives since
`id` is unique — **and that order is also the one harvesters expect.**

`ListRecords` pages smaller than `ListIdentifiers`, because `mods_xml_ss` is a
stored-only string holding the whole preservation MODS document.

## `OAIWorksQuery` is a sibling of `WorkDigestQuery`, not a subclass

It shares the ref vocabulary and the recipe, and every other decision differs: it
sorts by datestamp, pages with a `cursorMark`, carries the whole MODS document in
`fl`, keeps tombstoned records, and **gates on the literal `public` group rather
than a caller's.** A harvest feed has no authenticated principal, so the public
group is the whole of its visibility.

### Two deliberate non-filters

**`incomplete` Works stay in.** The flag marks a degraded but readable record and
by design flags without hiding. Dropping them would make records vanish from
Digital Commonwealth after a pipeline failure.

**Tombstoned Works stay in**, so a withdrawal is reportable. A Work that loses its
public read group instead just disappears, which is why `deletedRecord` is
`transient`.

### Why the in-progress filter is negative

`-in_progress_bsi:true` is negative on purpose. **A document indexed before the
field existed carries no value, and `in_progress_bsi:false` would drop it
silently.** `in_progress` defaults to true and flips at
`POST /works/:id/complete`.

### Membership is one rule, applied twice

A record must be a Work, publicly readable, and finished depositing. **Every
record also needs a datestamp:** a Work indexed before `OAIIndexer` shipped has
none, and a record with no datestamp cannot be harvested incrementally, so it
stays out until the reindex backfill reaches it.

`find` applies exactly the same rules as a list page, so a Work that is private,
still in progress, or missing a datestamp **is not in this repository at all** —
and the caller answers `idDoesNotExist` rather than leaking that it exists.

`compilation: nil` means the whole repository: a bare `ListRecords` with no `set`
argument, which the protocol requires a repository to answer.

## The `oai_dc` crosswalk

`OAI::DublinCore` projects `Metadata::MODS` onto the fifteen simple Dublin Core
elements.

**Deliberately off the JSON copy and never off the XML.** Reading MODS XML per
record would put a Nokogiri parse on an access endpoint, which this project does
not do — see [`mods.md`](mods.md). The JSON row exists precisely so a projection
like this is a cheap read.

**Solr cannot supply it either.** The index carries the fields discovery needs,
not the fifteen this crosswalk wants, and reassembling a record from facet fields
would be a second projection to keep in step. So the caller batches the rows with
one `Metadata::MODS.where(valkyrie_id: noids)` per page.

It is a minimum-viable projection, with two decisions worth stating.

**`dc:type` is populated.** v1's always came out empty, because the `oai` gem
skips a field called `type` to avoid Ruby's deprecated `Object#type`.

**Only creator-role names become `dc:creator`.** Every other role becomes
`dc:contributor`, because **flattening a thesis advisor into `dc:creator` would
put wrong attribution into a downstream catalogue.** `MarcRelators.creator?`
decides, so the code `aut`, the term `Author` and an absent role all land where
the display and the creator facet already put them.

### Names: an assertion, not a bucket

A name matches on **any** of its roles, so one recorded as both author and thesis
advisor harvests as both `dc:creator` and `dc:contributor`. That is what the
record asserts and what the display shows.

**A role-less name harvests as `dc:creator`.** It previously became a
`dc:contributor`, because `""` never matched "creator" — and since MODS makes
`mods:role` optional, that silently demoted every name a record did not bother to
role, and a name roled `aut` along with it.

`roles_of` keeps the single nil this crosswalk was written around:
`MarcRelators.creator?` reads nil as a creator, matching the display. **An empty
array would match neither branch and drop the name entirely.**

This is the same split [`mods-browse.md`](mods-browse.md) describes from the other
side: a facet must be disjoint and non-empty, an assertion need be neither.

### Subjects all flatten into `dc:subject`

Simple Dublin Core has one `dc:subject` and no way to say which kind.

`SUBJECT_AXES` is named rather than inlined **because it is a fourth list that
has to agree with `NEU::MODS::FIELDS` and nothing made it.** A new axis passed
every spec and was silently absent from `oai_dc`. A spec derives the list from
the registry now, the same guard `DISPLAY` and `SOLR_FIELDS` have.

Two axes are excluded, for opposite reasons:

- **`hierarchical_geographic_subjects`** has structured members, and flattening a
  hash into `dc:subject` would emit an object where a harvester expects a string.
  Its narrowest level already reaches geographic terms through Solr; a
  `dc:subject` rendering of it is a composition decision, not a list-membership
  one.
- **`subject_headings`** is excluded for the opposite reason to the display: a
  harvester wants discrete terms it can match, not one composed string, and every
  part of a heading is already here through its own axis.

### Dates ship as an interval

Publication date first, falling back to creation, at **day precision** — the
underlying column is a datetime, but a DC consumer wants a date.

**A ranged record ships the whole span as the ISO 8601 interval `1935/1940`**, the
form DCMI names for `dc:date`. Emitting the start alone would assert a single
date the record never claimed.

The qualifier is dropped on purpose, because simple Dublin Core cannot say
"approximate".

### Languages ship the bare term

`dc:language` takes a language code or name and nothing else, so the display's
"Spanish (subtitles)" is not a value to ship — **a harvester that read it would
have a string matching no vocabulary.** The Solr facet makes the same call for
the same reason.

### Identifiers: what resolves, ships

`dc:identifier` repeats, so a DOI ships beside the handle. Both are citable and
both resolve for anyone who harvests them.

**The local accession types stay out** — `COLID`, `BDR_METSID`. They resolve
nowhere outside the repository that minted them, and a harvester can only discard
them.
