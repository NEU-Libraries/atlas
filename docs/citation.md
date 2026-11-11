# Citations

`GET /works/{id}/citation` answers a Work's citation as a CSL-JSON item. CSL
(Citation Style Language) is the format reference managers and citation
formatters read, so a client hands the item to a CSL processor and gets APA,
Chicago or any other style. The planned Atlas MCP is expected to call it often.

Source files:

- `app/lib/citation.rb` — the rules: who made the Work, when, what type it is
- `app/indexers/citation_indexer.rb` — indexes the same creators and year
- `app/controllers/works_controller.rb` (`#citation`) and
  `app/views/works/citation.json.jbuilder` — the route

## One rule for creators and year

`Citation` is the only place that decides who made a Work and when.
`CitationIndexer` reads it to index `creator_ssim`, `contributor_ssim` and
`pub_date_ssim`, which search reports as `creators` and `year` and Cerberus reads
for its Google Scholar tags. The route reads it too, so the facet, the tags and
the citation cannot disagree.

- **Creators and contributors** come from the MODS names, split on the
  `MODSBrowse` creator and contributor axes. The two lists are disjoint.
- **The year** is the created date's year, the same date search reports.

## The CSL item

| Field | From |
|---|---|
| `type` | The first genre in `Citation::GENRE_TYPES`, else the type of resource in `RESOURCE_TYPES`, else `document` |
| `title` | The plain title, as the record pages compose it |
| `author`, `contributor` | The creators and contributors |
| `issued` | The created date at its stated precision (`[[1972]]`, `[[1972, 3]]`, `[[1972, 3, 4]]`), or `{"literal": …}` with the record's words when it gave a date it could not encode |
| `abstract` | The abstract |
| `keyword` | The topical subjects, comma-separated |
| `URL` | The permanent URL, the handle |

**Names are literal.** The JSON access copy keeps a name as one display string
and does not record whether it is personal or corporate. Splitting on a comma
would turn "Northeastern University (Boston, Mass.). Libraries" into a family
and a given name, so every name goes out as `{"literal": …}`, which CSL
processors print as written.

**An absent fact is left out, not sent as null.** CSL processors expect a missing
key. That is why the route's schema requires only `id`, `type` and `title`, and
why its spec checks the body through `json_schema :Citation` rather than rswag's
all-properties-required validation ([`openapi.md`](openapi.md)).

## Reads and caching

The route reads the JSON access copy and never parses XML, as the dual
representation requires ([`mods.md`](mods.md)). It shares the Work's read gate and
tombstone: a guest gets public Works only, and a tombstoned Work answers 410
below the operator tiers. The response is cached under `works.citation`, which a
write to the Work evicts with its other scopes.
