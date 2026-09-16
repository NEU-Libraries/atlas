# Atlas developer docs

Per-component reference that has to version with the code.

## What belongs here

Explanation a developer needs *while changing a specific file*, and that is too
long to sit inside it. For Atlas that means the MODS field registries, the four
credential paths, the OCFL write-path argument, Solr field derivations, and the
reason a design rejected the obvious alternative.

Each page names the source files it covers. Those files carry a one-line pointer
back, so you can find either from the other.

One page is not per-component. [`testing.md`](testing.md) covers the environment
and the workflow — the spec wrappers, the per-worker stores, the Solr cores, and
the guards. It lives here because it versions with the scripts it describes, and
because a developer needs it before any of the other pages make sense.

## What belongs elsewhere

| Audience or need | Home |
|---|---|
| The HTTP surface — paths, parameters, response shapes, status codes | `openapi/openapi.yaml`, rendered at `/docs` |
| A rule that code can check | a spec, not prose |
| Browser sessions, SSO, or anything a person sees in a browser | Cerberus's `docs/` |

The OpenAPI spec is generated from the request specs, so it cannot drift from
the API. Do not restate a response shape on a page here; link to the endpoint
and explain the part the schema cannot express.

Prefer a spec to a page here whenever the claim is testable. A spec fails when
someone breaks it; a page does not.

## The preservation constraint comes first

Atlas is a preservation system. The on-disk MODS XML and binaries are the source
of truth, and Postgres, Solr and the JSON access copy are rebuildable caches over
them. A page that explains a storage or serialization decision must say which
side of that line it sits on, because that is the fact a reader needs before they
change it. See the preservation-first principle in `CLAUDE.md`.

## Writing standard

Plain language, per ISO 24495-1:

- Put the answer first, the evidence after.
- Use the active voice, and name the actor.
- Use one term for one thing. If it is a Blob in the code, call it a Blob here.
- Reference code as `path:line` so a reader can open it.
- State a constraint as a constraint. Write "`WorkCreator` creates the
  descriptive-metadata FileSet", not "be careful when creating Works".

## The density target

A source file should keep its comments under about 35% of its non-blank lines.
That is a target for prose that belongs on a page here, not a rule to satisfy by
deleting knowledge. If a comment would cost someone a bug, keep it and go over.

**Files with fewer than 25 lines of code are exempt.** Density measures comments
against code, so a file that declares rather than computes has no denominator to
earn a budget with. `app/lib/mods_builder.rb` is the clearest case: seventeen
comment lines sit over twenty lines of code, and they explain which MODS elements
the template emits and why the order matters. Forcing that file under the target
would make it worse at the thing the target exists to improve.

A `PostToolUse` hook (`.claude/hooks/comment-density-lint.sh`) reports the number
after every edit under `app/`, and names the relevant page when the file already
has one. It is advisory: it runs after the write, so it cannot block anything.

The hook is developer-local. `.gitignore` excludes `/.claude`, so the hook does
not arrive with a clone and each developer installs their own. To measure a file
without it, count non-blank lines that start with `#` against the rest, treating
`# frozen_string_literal:` and `# rubocop:` as code.

## Adding a page

1. Group by the thing a developer is changing, not by the class name. Several
   files that share one pipeline belong on one page.
2. Name the source files at the top of the page.
3. Leave a pointer in each source file: one line, naming this path.
4. Keep in the source file only what someone editing that specific line must
   not miss. Everything else comes here.
