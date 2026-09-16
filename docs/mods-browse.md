# The browse vocabulary

Which semantic axis a displayed MODS value belongs to, and which Solr field holds
that axis.

Source file: `app/lib/mods_browse.rb`. Read by `MODSIndexer`, `CitationIndexer`
and `WorkDecorator`.

## Why the axis lives in one place

Atlas owns both halves of the browse problem. It writes the values a consumer
links to, and it renders the display a consumer puts links into. Those two have
to agree on the value, so the axis lives in one module all three readers consult
rather than being restated per file.

**A consumer cannot derive any of this from the rendered HTML.** That is why the
markers exist at all:

- One `<dt>` — "Subjects and keywords" — spans every subject axis, so the label
  does not identify the field.
- The rendered string is free to differ from the indexed one. A language row
  reads "Spanish (subtitles)" against an indexed "Spanish", and a name row
  carries its affiliation in brackets.

Matching on display text is unsound by construction, not merely fragile.

## The axis name is a MODS fact, never a Solr field name

Cerberus maps an axis to a facet from its own Blacklight config. So a facet
rename needs no Atlas release, and the eligibility rule can move without one
either.

`Axis` carries two members: `browse`, the token Atlas emits, and `solr`, the
field that holds it. **`solr:` is nil for an axis with no browse field.** The
marker is still emitted, because it costs one attribute and Cerberus links only
the axes its own facet config names.

## Subject axes

`SUBJECT_AXES` is keyed on the MODS element neu-mods reports as the heading's
main term. **A heading lands in the facet of its own axis:** "Salt marshes --
Massachusetts" is a topic heading with a place subdivision, so it browses as a
topic and not as a place.

| Key | `browse` | `solr` |
|---|---|---|
| `topic` | `topic` | `subject_ssim` |
| `geographic` | `geographic` | `subject_geo_ssim` |
| `temporal` | `temporal` | `subject_era_ssim` |
| `personal_name` | `personal_name_subject` | `subject_person_ssim` |
| `corporate_name` | `corporate_name_subject` | `subject_corporate_ssim` |
| `genre` | `genre` | `genre_ssim` |
| `title_info` | `subject_title` | `subject_title_tesim` |
| `occupation` | `occupation` | *(none)* |

Three of those rows are decisions rather than mappings:

- **`genre` shares the resource-genre facet.** A subject genre and a resource
  genre are the same vocabulary, so they share the facet a reader already
  browses.
- **`title_info` is searchable, not facetable.** A subject title is a work, so
  faceting would make one bucket per record.
- **`occupation` has no browse field.** None was asked for, and the term reaches
  search through the full-text catch-all. It is marked anyway, so adding a facet
  later needs no Atlas release.

### Three elements are absent on purpose

- **`hierarchical_geographic`.** The display composes a path across the levels
  while the Places facet holds the narrowest level alone, so the record has no
  single string that is both what a reader sees and what the index holds. A
  marker either way would name a value the row does not show.
- **`cartographics` and `geographicCode`.** Neither carries heading text, so
  neither can be a heading's main term.

## Non-subject axes

`CREATOR`, `CONTRIBUTOR`, `GENRE`, `LANGUAGE`, `PLACE_OF_PUBLICATION`,
`PUBLISHER` and `PHOTO_CATEGORY`.

Each names a field whose displayed value a reader might reasonably want to browse
by. **Whether a link is actually offered is Cerberus's policy call, not Atlas's.**
`publisher` and `place_of_publication` are marked even though the librarians
excluded them, because the exclusion is policy and lives with the consumer that
applies it.

## `name_axis`: creator or contributor, never both

A name with a MARC creator relator is a creator. A name whose roles are all
something else is a contributor. **The two are disjoint**, which is also how the
display groups them: a person is credited either as a creator of the work or as a
contributor to it, never as both under one heading.

**A role-less name reaches no axis.** MODS makes `mods:role` optional, and the
display files such a name under Creator or Contributor by its position — but
position is not a claim the record made, and neither `creator_ssim` nor
`contributor_ssim` holds it. A marker would promise a browse that returns
nothing.

### The OAI crosswalk splits the same two words differently

That is not drift. `Oai::DublinCore` answers a different question:

| | Browse facet | `dc:creator` / `dc:contributor` |
|---|---|---|
| What it is | A bucket a reader lands in | An assertion a harvester reads |
| A name recorded as both author and advisor | One axis, by relator | Emitted as **both** |
| A role-less name | No axis | Emitted as a **creator** |

A facet has to be disjoint and non-empty. An assertion has neither constraint.

## `vocabulary`: one attribute, two sources

The marker carries the vocabulary a value was taken from as a single string: the
`@authority` name when the record gives one, and the `@authorityURI` when it does
not.

**MODS lets a record declare its vocabulary by URI alone, and DRS holds corporate
names in exactly that shape.** `Northeastern University (Boston, Mass.)
Libraries` carries `authorityURI` and `valueURI` and no `@authority`. Reading
`@authority` alone left that value as plain text beside a linked creator on the
same record.

One attribute rather than three, because a consumer gates on the vocabulary being
*declared* and does not care which form declared it.

**The value's own `@valueURI` is not a candidate.** It names the value, not the
vocabulary, and a later external link reading this attribute would follow it to
the wrong place.

The method uses `try`, because the labeled fields that are not browse axes carry
none of these attributes at all.
