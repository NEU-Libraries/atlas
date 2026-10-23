# Conventions

The rules every change to Atlas has to satisfy, whoever or whatever writes it.
Procedure — the spec wrappers, the per-worker stores, the guards — is in
[`testing.md`](testing.md). The principle that outranks every rule here is in
[`preservation.md`](preservation.md): read it before any change to storage,
metadata serialization or persistence.

## Code

- Treat the NOID as the public identifier. `resource.noid` returns it, and
  `alternate_ids.first` is an implementation detail. `Resource.find` accepts a
  NOID or a Valkyrie ID; pass the NOID.
- Use `Atlas.persister` and `Atlas.query` in app code, not the
  `Valkyrie.config.metadata_adapter` chain.
- Create a resource through its service object in `app/services/`, such as
  `WorkCreator.call(parent_id: …)`. Do not save a bare `Resource.new`: the
  service object fires the side effects, such as the descriptive-metadata
  FileSet and the parent's permissions.
- Decorate a resource before a view sees it. Controllers call `.decorate`
  before they assign `@resource`, and the jbuilder partials assume the
  decorated interface.
- Paginate an index action with `LazyPagination`: `paginate_model(Work)`
  returns `[pagination, items]`.
- Keep MODS work on the write path. Do not parse XML with Nokogiri in a
  controller or a decorator; [`mods.md`](mods.md) explains the dual
  representation that makes reads fast.

## Response shapes

- Define a response body only in its jbuilder partial,
  `app/views/<resource>/_<resource>.json.jbuilder`. Do not build one inline in
  a controller or with `render json:`.
- Change the partial and its schema in `spec/support/openapi_schemas.rb`
  together. Strict schema validation fails the request specs when they differ.
- Regenerate `openapi/openapi.yaml` with `bin/openapi`, and commit it with the
  change. CI fails when the committed file differs from what the specs
  generate.

## Lint

The rubocop baseline is clean, so a new offence belongs to the change that
added it. `.rubocop.yml` carries Atlas-specific exclusions, each with its
reason beside it. Do not fight them. Data tables such as
`app/lib/marc_relators.rb` are excluded from every cop, and the
`Rails/DynamicFindBy` whitelist holds `find_by_alternate_identifier`, which is
a Valkyrie method rather than an ActiveRecord one.

## Comments

A comment earns its place only when it explains why the code immediately below
it exists. It must still make sense to a reader two years from now who has no
access to git history or planning documents. Keep it to two or three sentences.

Do not write temporal or working-artifact comments:

- No dates, app version stamps such as `0.6.x`, or `(Fixed YYYY-MM-DD)`
  markers.
- No planning shorthand: `piece N`, `Q<n>`, `Gap C`, named initiatives, or
  pointers to files outside the repository.
- No before-and-after narration, such as "used to", "no longer", "previously"
  or "was X, now Y". Describe the current design and its reason. Git holds the
  old design.

Keep real rationale, wire-contract constraints and gotchas, but drop the
incident: keep the lesson, not the date it bit. A deferred fix is a one-line
`TODO:`, not a paragraph. This is a standard for *why* comments, not a rule
against comments.

Most explanation belongs on a page in `docs/`, not in the file. What stays in
the file is the trap: a comment that someone editing *this line* would break
something without. A wire-contract gotcha, an ordering constraint, a rule that
looks redundant but is not, and every `rubocop:disable` justification stay
inline. Everything else goes on a page, and the file keeps a one-line pointer
to it. [`README.md`](README.md) covers when to add a page and the comment
density target.

Never restate a response shape on a page. The request specs generate
`openapi/openapi.yaml`, so it cannot drift; a page links to the endpoint and
explains what the schema cannot express.

Prefer a spec to prose whenever the claim is testable. A spec fails when
someone breaks it; prose does not.
