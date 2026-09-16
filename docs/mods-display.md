# Rendering MODS for display

How a projected MODS field becomes a row a reader sees, and why the rendering
makes the claims it does.

Source files:

- `app/decorators/work_decorator.rb` — the `DISPLAY` table and the per-field renderers
- `app/helpers/decorator_helper.rb` — the HTML primitives every row goes through

The dual representation is [`mods.md`](mods.md). The browse markers these rows
carry are [`mods-browse.md`](mods-browse.md).

## One rule runs through all of it

**Render only what the record claimed.** Most decisions on this page follow from
that. A year-only date must not print a month. A role-less name must not assert a
creator. A record that gave no scale must not be told off for it. An identifier
the record called invalid must not silently vanish.

The second rule is that a reader scanning a page must not mistake a doubtful
value for a certain one, which is why qualifications ride the visible string and
never a tooltip. A tooltip leaves a bare value on screen, and a screen reader may
not announce the attribute at all.

## `DISPLAY` is the one place a row is added

The views render `#mods_rows` rather than listing fields. **Before that, a field
could be projected and stored and then silently not render because someone forgot
a line in two byte-identical templates.**

The order is the librarians' own: identity elements, then discovery elements, then
utility elements.

| Key | Meaning |
|---|---|
| `:field` | The projected field this row reads |
| `:label` | What a reader sees *when the record asks for nothing else*. A record's own `@displayLabel` outranks it, and inside an `originInfo` block so does `@eventType`. |
| `:render` | Names a method, for a field whose markup is more than a label and a value |
| `:within` | Names the row that renders this field instead, for a field the librarians asked to show with no header of its own |
| `:capitalize` | The one per-value transform a plain row needs |
| `:axis` | The browse a plain row's values belong to |

There is no `:link` key. A link now rides on the value itself.

**Labels live here and not in neu-mods on purpose.** A label is display
vocabulary, and Cerberus's edit form words the same field differently. The gem
owns what a field *is*; this file owns what it looks like.

## No row heads itself

`grouped_rows` produces one row per header, in the order the headers first
appear. **A record that labels one of two values asks for two headers**, so values
group by the header they carry rather than by the field they came from.

The block it takes answers with `[header, value]` for one entry, or nil to drop
it. A value may be a list, for a row whose entry renders several `<dd>`s.

## Coverage: what renders nowhere, and why

`NOT_DISPLAYED` lists every projected field with no row of its own, so the
coverage spec can tell a deliberate omission from a forgotten one. Everything
below stays projected onto the access copy, and stays in the preservation XML.

### Four whole dates

- **`dateCaptured`** is when the object was digitised, and **`dateModified`** is
  when the resource changed. Both are preservation and cataloguing provenance
  rather than description, so they follow `record_info`.
- **`dateValid`** and **`dateOther`** are descriptive, and a librarian decided
  against a row for both. Neither answers a question a reader of this repository
  asks, and `dateOther` means whatever the cataloguer meant.

All four stay projected so the API and the OAI crosswalk can read them.

### `record_info`

Cataloguing and preservation provenance rather than a description of the
resource. Five rows of identical text beside Publisher buy a reader nothing.

It stays projected rather than left in the preservation XML alone, so the API and
the OAI crosswalk can read that provenance **without a Nokogiri parse on a read
path**.

### `physicalDescription/form`

The librarians' decision: it duplicates the extent and the digital origin beside
it, in vocabulary a reader does not use.

### The subject axes

`#subject_headings` renders them, joined back into the heading the cataloguer
built. **Split apart they asserted independent subjects the record never
claimed:** one LCSH heading became rows under three labels, and the string a
cataloguer typed appeared nowhere.

They stay projected for the OAI crosswalk, which wants discrete terms a harvester
can match. The Solr facets no longer read them — a facet holds the whole heading
now, so the string a reader clicks is the string the index holds.

**`geographic_code_subjects` is the exception within the exception.** A MARC GAC
code is not heading text, so it is neither a row nor a part of one.

### The date parts and the companion labels

`DATE_PARTS_NOT_DISPLAYED` is derived rather than written out, because seven
dates times eight parts is fifty-six near-identical lines.

None of those parts is a row. The precisions choose the format; the end value and
the qualifier are composed into the date string; the key-date flag chooses which
date sorts; the text carries the literal a record wrote in something other than
w3cdtf; and the label and the event type head the row rather than fill it.

The six companion labels and hrefs work the same way: each is read by the row of
the field it names.

## Dates

### Precision picks the format

`DATE_FORMATS` maps `year`, `month` and `day` to `%Y`, `%Y-%m` and `%Y-%m-%d`.

**A year-only date parses to 1 January**, so a hardcoded `%Y-%m-%d` would print a
month and a day the record never claimed, indistinguishable from one that did.

An absent or unrecognised precision keeps the full-date format, so a record
stored before the gem carried precision renders exactly as it used to.

### Qualifiers change the visible string

| Qualifier | Renders as |
|---|---|
| `approximate` | `circa 1935` |
| `inferred` | `[1935]` |
| `questionable` | `1935?` |

These are conventions cataloguers already use, so they read as intended rather
than as a rendering bug.

### An end with no beginning reads "before"

`<dateCreated point="end">1921</>` says the resource is no later than 1921 and
nothing more. The bare year would assert a date the record refused to give, so
`END_ONLY_DATE_PREFIX` puts "before" in front of it.

### A date renders everything the record declared

The value at its own granularity, the other end of a range at the end's own
granularity, and the qualifier around the whole thing. "circa 1935-1940" is
honest where both "1935" and "1935-1940" are not.

**A record whose date is not w3cdtf or ISO 8601 has no value to format**, and the
gem hands over the literal instead. Showing "19uu" is what the record says; the
alternative is a row a cataloguer filled in that no reader ever sees.

## Names

A name appears under **every** role it declares. A person recorded as both author
and contributor is two assertions, so the repetition is what the record says
rather than a duplicate.

### Three labels for a name with no usable role

| Constant | Value | When |
|---|---|---|
| `NO_ROLE_LABEL` | `Creator` | A role-less name that **leads** |
| `TRAILING_NAME_LABEL` | `Contributor` | A role-less name that does not lead |
| `UNKNOWN_ROLE_LABEL` | `Other contributors` | A name whose only roles are MARC codes this system does not hold |

**A role-less lead is labelled rather than left bare.** MODS makes `mods:role`
optional, and a nil label rendered an empty `<dt>`: the name read as a value of
the field above it, and a screen reader announced it under an empty term. v1
labelled these "Creator", so this restores a convention rather than inventing
one, and a role-less lead merges with an explicit Creator group.

**The trailing names are contributors because of what the record said.** A record
listing six names and marking none of them said one thing: these people were
involved. Filing all six as creators asserts six creators, which is the claim the
librarians asked to stop making.

**An unknown relator code still renders the name.** Losing it over a typo is
worse than filing it loosely, and it is kept apart from Creator because the
record did not say creator. A heading comes from one list the system controls, so
an unlisted code must not become one.

The code itself is shown nowhere, and that is settled. A curator proofing a
record reads the XML for what the record literally says, and a reader has no use
for a relator code this system cannot name.

**The unknown-role label is a last resort, not a per-role one.** A name carrying
`aut` and a typo'd `qqq` was filed under both, so a reader saw the same person
twice, the second time under a role the record never asserted. A name with at
least one known role is already filed correctly, and the unrecognised code adds
nothing but the duplicate.

### `PRIMARY_USAGE`

What a name's `@usage` has to say to nominate itself. Fixed in the schema, so
there is exactly one value to match.

### A nameless name is skipped

neu-mods drops one now, but an access copy stored before that still carries
`{ name: nil, roles: ["edt"] }`, which rendered a labelled empty row.

## The other renderers

### Identifiers

**The type leads the value**, because a DOI and a local accession number are not
the same kind of thing and a reader cannot tell them apart from the digits. It is
upcased rather than titleized: these are codes, so "DOI" reads right where "Doi"
does not.

**An identifier the record calls invalid is marked, not suppressed.**
`INVALID_IDENTIFIER_MARK` is `(invalid)`. In MODS the attribute means cancelled,
superseded or wrong, and a cancelled ISBN is exactly what a reader chasing an old
citation has in hand — so it is worth showing, and worth saying it will not
resolve. Words rather than a symbol, and beside the value rather than in a
tooltip, for the reason the date qualifiers give.

### Languages

"Spanish (subtitles)". An `@objectPart` says the language belongs to part of the
object, not to the object — **a captioned video is not in the language of its
captions** — so the row must carry the qualification or it makes a claim the
record did not.

The Solr facet still gets the bare term, so a search for Spanish finds this
record either way.

The script joins the same parenthesis. It qualifies the term for the same reason,
and a second bracket beside the first would read as two things.

### Related items

**Only a top-level `relatedItem` reaches here.** The gem scopes its XPath to the
document root, so a `relatedItem` nested inside another does not display. That is
the same call as suppressing a host's own metadata: it describes the other
record, not this one.

**A `relatedItem` is headed by what the relationship is.** The type used to lead
the value — "Otherformat: the print edition" — which put a camelCased attribute in
front of a title and still left every relationship under one heading.

### Host collections

"Estuaries, 24(3), pp. 210-218, 1998".

The host's editor, publisher and ISSN stay out. They are the other record's
metadata, and a reader who wants them should reach that record rather than read a
copy that goes stale.

**A host that names no title renders its position alone.** The position describes
this work and no other record holds it, so dropping it because the host block
carried no `titleInfo` would lose the one part that was ours.

### Map data

Composing "scale ; projection ; coordinates" is display policy, which is why the
gem leaves `cartographics` structured and the join happens here.
`MAP_DATA_SEPARATOR` follows the MODS display convention.

**Every part takes the separator.** Projection and coordinates shared one slot
and collided on a space, so a reader could not see where the projection name
ended and the coordinates began.

**A record that gave no scale gets no scale.** Printing "Scale not given" put an
editorial complaint on a geotagged photograph that never claimed to have one.

### Place levels

`PLACE_LEVELS` lists `hierarchicalGeographic` levels broadest to narrowest.
`MODSIndexer` reads them from the narrow end, so a record naming a city is browsed
by its city rather than by its continent.

### Subject headings

`composed_heading` prefers the joined form neu-mods composes, so the display and
the browse index cannot separate a heading differently.

**An access copy stored before neu-mods 0.14.0 carries the parts and no joined
form**, and a reindex is what repopulates it. Between a deploy and that reindex
the parts are joined here instead — through the gem's own separator, which is
what keeps this from being a second join with a mind of its own.

## The HTML primitives

`DecoratorHelper` holds the primitives every row goes through. Two of its methods
return `html_safe` strings, and each carries its `rubocop:disable` justification
inline.

### `enhanced_text` and `linkify`

Both render curator-authored text as a safe HTML fragment: escape the value, then
revive only a bare `<sub>` and `<sup>` from a tiny allowlist.

They differ in what comes after:

| | `enhanced_text` | `linkify` |
|---|---|---|
| Input | A single-line value — a title | Freetext — an abstract, a note |
| Paragraphs | None | Splits on blank lines, wraps each in `<p>`; lone newlines collapse to a space |
| URLs | Not detected | Auto-linked when they survive a strict `URI.parse` |

`enhanced_text` omits the paragraph wrapper because a title is one line, and a
`<p>` inside the `<dd>` would change a shape every consumer of the MODS HTML
block already lays out.

`linkify` emits `<p>` uniformly so consumers like Cerberus can own vertical
spacing through CSS. Anything that fails to parse as a URL stays as plain escaped
text.

### Autolinking walks an already-escaped stream

`autolink` receives HTML in which only `<sup>`, `<sub>` and the `<p>` wrappers
survive, so it walks the string splitting around tags. Tags pass through
untouched; text segments get URL detection with non-URL text re-escaped.

Text segments are already escaped — `&` has become `&amp;` — so `autolink_text`
decodes entities to recover the real URL, validates it, and emits a properly
escaped `<a>`.

### The URL boundary problem

The URL regex is greedy and stops only at whitespace, so a paste like
`(http://example.com)Copyright` matches everything from `http` to the final `t`.

`split_at_url_boundary` walks the match tracking bracket balance. **The first
closing bracket without a matching opener inside the URL is where the URL really
ends.** That keeps Wikipedia-style `Foo_(disambiguation)` URLs intact while
peeling off stray `)Copyright...` text.

`URL_TRAILING_PUNCT_RE` holds sentence terminators only. **Brackets are
deliberately absent from it**, because bracket balance is
`split_at_url_boundary`'s job.

Text the regex slurped past the real boundary is prepended to the remainder, so a
second URL hidden in there still gets matched on the next pass.

### `browse_value` and `linked_value`

`linked_value` renders a value with the link the record attached to it
(`xlink:href`), or the value alone. HTML5 gives an anchor a transparent content
model, so wrapping the paragraphs of an abstract is valid and the paragraphing
survives the link.

`browse_value` marks a value with the browse axis it belongs to, for a consumer
that injects this HTML whole and has no other per-value handle on it. The `<span>`
carries the axis, the exact string the index holds, and the vocabulary the term
came from.

**`text` is what a reader sees and `value:` is what the index holds, and they are
not the same string in general.** That difference is the point — see
[`mods-browse.md`](mods-browse.md). A consumer matching on rendered text would
miss both cases, which is why the indexed value is stated rather than inferred.

**A value the record linked with `xlink:href` takes no marker.** It already has an
anchor, and a consumer wrapping the marker in a second one would nest `<a>` inside
`<a>`. The record's own link wins, because it is the more specific claim.

The marked value renders without the paragraph pass. A browse candidate is a
controlled term on one line, so there is no blank-line break to keep and no URL to
autolink. The `<p>` wrapper is still added, so the row keeps the shape every
consumer already lays out.

### `labeled_field` and `html_field`

`labeled_field` renders one label and one value, or nothing at all when the value
is blank — so a sparse record shows no empty `<dd>` under a heading like "Date
created". **The label is resolved by the caller**, because which of
`@displayLabel`, `@eventType` and the field's own name wins is display policy
that differs per field.

`html_field` takes one label over many values that are **already** rendered HTML.
Running them through `linkify` again would escape the anchors it just produced.
