# Solr indexing

What Atlas projects into Solr, what it deliberately does not, and why each
decision went the way it did.

Source files:

- `app/indexers/mods_indexer.rb` — the descriptive field registry
- `app/indexers/sort_indexer.rb` — the three sortable fields
- `app/indexers/citation_indexer.rb` — creators, contributors, publication year
- `app/indexers/name_variant_indexer.rb` — diminutive and formal forms of personal names
- `app/indexers/person_indexer.rb` — a Person as a first-class result
- `app/indexers/thumbnail_indexer.rb` — thumbnail-family Delegate URIs

The browse-axis vocabulary these indexers share with the decorator is
[`mods-browse.md`](mods-browse.md).

## Two facts shape everything here

**Atlas and Cerberus share one Solr core** (`blacklight-core`). An Atlas-side
indexer is therefore enough to feed Cerberus's catalog reads; there is no
Cerberus-side write path.

**No indexer parses MODS XML.** Every source is the JSON access copy, reachable
as `resource.mods`. That holds on the write path as well as the read path — see
[`mods.md`](mods.md).

`config/initializers/valkyrie.rb` composes these indexers into the
`:composite_persister`, so they all fire on every resource save.

## Field names are Cerberus's contract

The Solr field names follow what Cerberus's Blacklight config already declares.
**Repointing a facet is a config change there, not a rename here.**

Indexing a field is necessary but not sufficient for it to be *searched*. That
also needs the field in the request handler's `qf`, which the `blacklight-solr`
image owns. `identifier_tesim`, `full_text_tesimv` and `title_plain_tsim` all
depend on that.

## `MODSIndexer`: three buckets, so the coverage guard can tell them apart

A projected field falls into exactly one of three constants, and the split is
the point — it lets the coverage spec distinguish decisions from oversights.

| Constant | Meaning |
|---|---|
| `SOLR_FIELDS` | One Solr field per projected field |
| `AXIS_FIELDS` | The Solr field is chosen **per value**, by browse axis |
| `NOT_INDEXED` | Deliberately not written, with the reason as the value |

`SOLR_FIELDS` mirrors `WorkDecorator::DISPLAY`: one declarative row per indexed
field, **so a field cannot be projected, stored, displayed and then silently
absent from discovery.** That is exactly what happened to `languages` —
extracted, rendered, and zero values in Solr across every document, so a
language facet was impossible rather than merely unconfigured.

`NOT_INDEXED` is a map rather than a list so that "another indexer owns it" is
distinguishable from "no discovery value". Those are different decisions, and
only the second is one to revisit.

### Two rows in `SOLR_FIELDS` are decisions, not mappings

**`hierarchical_geographic_subjects → subject_geo_ssim`.** It joins the Places
facet at its narrowest named level. `bdr_43888.mods.xml` uses this axis *instead
of* `subject/geographic`, so without the row that record is browsable by no place
at all. It is the one subject axis not indexed through `AXIS_FIELDS`, because the
narrowest level is what a reader browsing Places wants while the heading composes
a whole path.

**`classification → photo_category_ssim`.** DRS writes IPTC photo categories
here — portraits, community outreach — rather than the classification-scheme
value MODS defines the element for, so the Solr field is named for what it
actually holds.

It is deliberately **not** `classification_ssim`. That field carries the FileSet
content-type vocabulary (Image, Map, Musical Notation) and drives Cerberus's
shipped Content facet, so mixing the two would corrupt a working facet.

### `identifiers` is searchable, not facetable

Faceting on an identifier would make one bucket per record.

### `LABELED_MEMBER_VALUES`: which attribute carries the text

Some projected fields hold models rather than strings, and this map names the
attribute with the indexable text.

- **A DOI** has to reach Solr as the digits a reader pastes, not as the model's
  `inspect` output.
- **A host facets on its title alone.** Bucketing on the composed citation would
  make one bucket per article, since the volume and pages differ on every
  record.
- **A language facets on its term alone.** The `@objectPart` qualifies the row a
  reader sees, but bucketing "Spanish (subtitles)" apart from "Spanish" would
  split one language across two facet entries and hide the record from a reader
  browsing either.

Every field a record can re-head with `@displayLabel` projects as
`{ value:, display_label:, href: }`, and Solr takes the `value`: **a record that
re-heads its place row has not moved the place.** Those rows are derived from the
access copy's own declaration rather than restated, so a field that gains a
header cannot start indexing a model's `inspect` output.

### `AXIS_FIELDS`: a heading is indexed whole

`subject_headings` is the only per-value field, and it has to be one: every
subject axis arrives under it, and a heading belongs in the facet of its own
axis.

**A heading is indexed as the whole composed heading, not as its parts.** That is
the librarians' decision, and it is the one part of the browse work that is not
additive. "Emergency management" and "Planning" used to be two `subject_ssim`
values and are now one, "Emergency management -- Planning". A single-child
subject is untouched.

**The cost is known and accepted:** a whole-heading entry does not roll up into
its parts, so a reader on the subdivided heading never sees the plain-topic
records. The agreed exit is to index the heading *and* its parts, which is
another reindex rather than a migration. **That is why the code emits a list per
field and never a scalar.**

### The reproject-before-reindex ordering

**The axis comes off the stored access copy, so `rake atlas:mods:reproject` has
to run before a reindex when the gem's projection is newer than the rows.**

An access copy written before neu-mods 0.14.0 names no axis, and a reindex over
those rows would **empty every subject facet** rather than move it. The XML is
the source of truth, so the recovery is to reproject and reindex again — but the
order is not optional.

### Companions and date parts are derived, not listed

`DATE_PARTS_NOT_INDEXED` and `COMPANIONS_NOT_INDEXED` are both computed from
`NEU::MODS::FIELDS`.

Writing them out would be forty-two near-identical rows for the dates alone, and
**a date added to the gem would need six more or the coverage guard fails on
fields nobody meant to index.** Deriving them means a field that gains a
companion cannot go unlisted.

The reasons themselves are worth keeping:

| Part | Why it is not indexed |
|---|---|
| `precision`, `end_precision` | Chooses a display format; not a value a reader searches |
| `end` | The far end of a range; a range sorts and facets on its start |
| `qualifier` | Renders into the date string |
| `key_date` | Chooses which date `SortIndexer` sorts on; not a facet |
| `text` | The literal of a non-w3cdtf date; a display value, and unsortable |
| `display_label`, `href`, `event_type` | A header or link the record asked for |

The companion argument generalises the date one: **a display value is not a term
a reader types, and faceting on one would bucket records by their cataloguer's
wording rather than by what they are about.**

### `narrowest_place`

A reader browsing Places wants Parksville, not United States. The broader levels
are implied by the narrow one, so indexing all of them would bury the useful
value under a continent every record shares.

### `title_plain_tsim`: the match-only twin

`title_tsim` is both the match field and the display field a result row renders,
so it keeps the record's `<sub>` and `<sup>` markup. **That makes Solr tokenise
"sub" as a term of its own and leaves "Bi2Sr2CaCu2O8" — the formula a reader
types — matching nothing.**

`title_plain_tsim` is the same title with the markup removed. Stripping
`title_tsim` instead would fix matching and break every result heading.

It is written only when the two differ, so an ordinary title is not indexed
twice.

### Operational flags project unconditionally

`in_progress_bsi` and the `Work#incomplete` pair are written whether or not MODS
metadata exists, so `/works?in_progress` can find stuck deposits before anyone
has filled the metadata in.

Both incomplete fields reach Solr because a consumer renders the "Incomplete"
pill and its cause **straight from the search document**. An unindexed field
cannot drive it, and a per-row fetch to read one flag would defeat the result
list.

### A field is written only when it has a value

So a sparse record carries no empty facet entries. The field appears the next
time the resource is saved or reindexed — the same lifecycle `genre_ssim` has.

## `SortIndexer`: three fields that exist only to be sorted on

| Field | Source |
|---|---|
| `title_ssi` | The composed title, normalised |
| `creator_ssi` | The primary creator's name |
| `date_ssi` | The MODS origin date |

**Solr sorts on a single-valued field only**, and every descriptive field Atlas
indexes for display is multi-valued (`title_tsim`, `creator_ssim`) or, for an
origin date, not indexed at all.

So a Sort control offering title, creator or date had nothing to sort on — and
**the failure is silent**: Solr accepts the sort, finds the field missing on every
document, and returns index order. These three fields are never displayed.

### `date_ssi` and `created_at_dtsi` are different sorts on purpose

`created_at` is when the repository made the record. `date_ssi` is when the thing
itself was made. **For an archival scan the second is the only date a reader
cares about.**

### Normalisation keeps every letter

`SORT_NOISE` is `/[^\p{L}\p{N} ]/` — sorting ignores punctuation and case, but
never a letter. A letter outside `a-z` folds to the base letter underneath it
where there is one and is otherwise kept as itself, **so nothing a curator can
type leaves a resource with no sort key at all.** A kept character sorts by
codepoint, which groups a script together after the Latin range.

`fold` case-folds, then decomposes so a diacritic becomes a separate
`COMBINING_MARK` to drop, then transliterates the letters those two leave whole.
Together they are **the same folding Solr's `ICUFoldingFilter` already applies to
`title_tsim`**, so sorting and matching agree on what a letter is.

Unicode's own case folding covers a letter with no decomposition but an
equivalent — the eszett to "ss", a final sigma to a medial one — and the
transliteration table covers the rest, a slashed o to "o" and a thorn to "th".

The field names are v1's, and for ASCII text so is the normalisation, **so a sort
that worked in v1 orders the same way here.**

### Titles

`composed_title` drops the `nonSort` prefix, because **MODS records the article
as `nonSort` precisely to say "do not sort on this".** `LEADING_ARTICLE` then
catches the records that put the article in the title instead.

Composition reuses the shared helper the display title uses, so the two orders
agree on subtitles and part numbers.

**Enhanced-text markup is stripped before normalising.** `SORT_NOISE` drops `<`,
`>` and `/` as ordinary punctuation, which welds the word "sub" and the subscript
digits into the key — `bisub000002subsr...`. The sort field is never displayed,
so plain text is unambiguously right here.

### The display-name fallback

`title_ssi` is the sort form of whatever `title_tsim` displays, for every
resource type. Holding to that for a Person is why the title source falls back to
a display name: **a Person's title is their name, a Person carries no MODS, and a
Person reaches ordinary catalog results**, so an A-Z list has to order one by
their name.

`PersonIndexer` already projects that same `display_name` into `title_tsim`, so
the two agree. A Person with no sort title would sort as missing.

### The primary creator

The first name in a creator role, or — when no name declares one — the first name
of any role, **so a resource whose only names are contributors still sorts under
a name instead of to the end of the list.**

A name keeps its punctuation, because "Lee, Wen-Han" is already in filing order.
It is case- and diacritic-folded like a title, so a name opening on an accented
letter files under that letter rather than after Z.

### Dates

**MODS lets a record nominate its own principal date with `keyDate="yes"`, and a
flagged date wins.** `DATE_FIELDS` previously overruled it with a fixed
preference for `dateCreated`; that order is kept for the records that set no flag
— most of them — and for the ones that flag the date it would have picked anyway.

**A ranged date sorts on its start.** That is what it did before by accident,
because the gem returned the first node. It is deliberate now, so the behaviour
survives the gem reading the points by attribute.

## `CitationIndexer`

Projects the citation-relevant fields onto the Work's own Solr doc so Cerberus
can emit Highwire Press and Google Scholar `<meta>` tags in the Work show
`<head>` **without parsing MODS XML on every render** — a hard DPS design
constraint.

The Work doc already carries title, abstract, genre and access. This indexer adds
the three pieces Scholar needs that were missing:

| Field | Feeds |
|---|---|
| `creator_ssim` | One `citation_author` each, in display form |
| `pub_date_ssim` | `citation_publication_date`; single value, reusing Cerberus's existing "Publication Year" facet field |
| `contributor_ssim` | No Scholar tag — see below |

**`contributor_ssim` rides along here rather than in `MODSIndexer` because it is
the same filter over the same `names` projection that `creator_ssim` is, only
inverted, and the two have to stay disjoint.** A second file applying its own
role rule is how one name ends up in both facets or in neither.

Contributor names previously reached Solr under no name at all —
`Flynn, Stephen E.` was findable only through the `all_text_timv` catch-all — so a
contributor facet was impossible rather than merely unconfigured.

`MODSBrowse` decides which axis a name belongs to, so the facet and the display
markers cannot disagree. **A marker naming an axis the index does not hold is a
link that leads to an empty result set.**

### The keywords meta reads `subject_ssim`

Which `MODSIndexer` writes for every Modsable resource rather than for Works
alone. This indexer used to write the same values as `keyword_ssim`; that name
said "keyword" while carrying `topical_subjects`, which are a wider set than the
gem's `#keywords` — and having two indexers write one concept meant either could
drift.

## `NameVariantIndexer`

Writes `name_variant_teim` so that a search for "Tim Smith" finds a record naming
"Smith, Timothy", and a search for "Nicholas Myers" finds a photo keyworded
"Nick Myers". Readers treat a diminutive and its formal name as the same name,
and Solr does not. The field is match-only: `*_teim` is indexed and not stored,
and nothing displays or facets it.

The table is two public-domain CSV files vendored under `vendor/diminutives.db/`,
read by `app/lib/name_variants.rb`. A name expands to every other name that
shares a row with it. "Tim" sits under both Timon and Timothy, so it expands to
Timon, Timothy and Timmy.

### Where the names come from

| Source | Rule |
|---|---|
| `names` (every `mods:name`, any role) | Always a candidate |
| A `personal_name` subject heading | Its first part, so subdivisions are ignored |
| A `topic` subject heading | Only when it is one part, two or three words, and every word is capitalized |

**Topics matter most.** Cerberus's IPTC ingest writes each person in a photo as
a plain `mods:topic`, with no name markup, so the names a photo search most needs
arrive as topics.

**The table is the only test of whether a string is a name.** A name parser such
as Namae cannot do that job: it assumes its input is a name, and reads
"Northeastern Alumni" as given name "Northeastern". The shape rule for topics
only keeps long phrases and lowercase keywords out. A string expands only when
its given name is a row in the table.

### Splitting a name

The comma form is how neu-mods composes a personal name (`Smith, Timothy J.`).
Direct order is how a photo desk writes one (`Nick Myers`). A trailing LC date
(`, 1917-1963`) is removed first. The given name is the first word after the
comma, or the first word of a direct-order name. A middle name or initial is
dropped. Each variant is written in direct order with the family name
(`Tim Smith`), so a quoted phrase search matches as well as a plain one.

A name without a family name expands to nothing. A titled name such as
`Dr. Timothy Smith` also expands to nothing, because "Dr." is not in the table.

### Known false positives

Many diminutives are also English words: Art, Bill, Frank, Grace, Mark, Max and
Rose among them. A topic such as "Art Exhibit" passes the shape rule, so a search
for "Arthur" can match it. The two-word minimum keeps a lone "Art" or "Bill" out.
Ambiguous diminutives widen the match: "Jo" sits in seven rows. The field needs a
low boost in the search handler's `qf`, below the names it was derived from, so
a variant match always ranks under a real one.

"will" is a stopword in the search handler's analyzers, so a query for "Will"
cannot reach this field. A record naming "Will Jones" still matches a search for
"William".

To stop a row expanding, filter it in `NameVariants`. The vendored files stay
byte-identical to upstream.

## `PersonIndexer`

A Person doc reaches ordinary catalog results, because **Cerberus's type filter
is a denylist of the file-level types** (`-FileSet`, `-Blob`, `-Delegate`) which a
Person passes. Treat a Person as a first-class result throughout, not a
People-surface special case.

| Field | Why |
|---|---|
| `title_tsim` | `display_name` in the standard title field every other type uses. This is what makes a Person a first-class Blacklight result: Cerberus displays it through `index.title_field` and keyword-searches it because `qf` targets tokenized `*_tsim`. So `q=David Cliff` matches the Person and the row renders with a name rather than the id. |
| `type_ssim` | `['Person']`, so Person is a Type-facet value alongside Work, Collection and Community. Overrides the auto-projected `type` attribute — the human label "Faculty and Staff" — for the facet field only. |
| `display_name_ssi` | The authoritative, librarian-editable name. What every name render should resolve to. |
| `noid_ssi` | The public address. The community Faculty-and-Staff browse links to `/people/:noid`, so it needs the NOID explicitly rather than parsing `alternate_ids`. |
| `nuid_ssi` | The correlation key, server-side only. |
| `affiliated_community_ids_ssim` | Affiliated communities as NOIDs, matching `ancestor_ids_ssim`'s shape, so a community page pulls its Persons with one `fq`. |
| `personal_root_id_ssi` | The personal-root Collection's NOID. Cerberus reads it off the Person JSON instead; indexed for discovery and to verify provisioning from Solr. |

**The NUID is not added to any title or searchable field.** IT Security: no NUID
in search responses.

`display_name` is auto-indexed as `display_name_tsim` as well, but `qf` targets
the title field and not that one, which is why `title_tsim` is set explicitly.

## `ThumbnailIndexer`

Projects thumbnail-family Delegate URIs from a resource's `:derivative` FileSet
onto the resource's own Solr doc, so Blacklight can render row thumbnails
**without re-assembling IIIF URLs from a UUID.**

`to_solr` runs when the **parent** resource is saved. `DelegateCreator` and
`DelegateUpdater` explicitly re-save the parent after mutating a Delegate so the
parent's doc reprojects with the new URIs.

It returns an empty hash for resources with no derivative FileSet — Blobs,
Delegates, FileSets themselves, and resources whose ingest has not minted
derivatives yet. The composite indexer fires on every save, so that early return
is what keeps the fast path fast.
