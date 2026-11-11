# frozen_string_literal: true

# The frame of the two generated OpenAPI documents: everything but the paths.
# The public document is the one `/api-docs` serves; the internal one holds the
# operator and backend operations and is never served. docs/openapi.md says
# which operation goes where, and why the internal file sits outside the served
# root.
module OpenapiDocument
  PUBLIC   = 'public/openapi.yaml'
  INTERNAL = 'internal/openapi.yaml'

  DOCS = 'https://github.com/NEU-Libraries/atlas/blob/develop/docs'

  module_function

  def specs
    {
      PUBLIC   => frame(title: 'Atlas API', description: PUBLIC_DESCRIPTION, tags: PUBLIC_TAGS,
                        security: [{ BearerAuth: [] }, {}]),
      INTERNAL => frame(title: 'Atlas internal API', description: INTERNAL_DESCRIPTION, tags: INTERNAL_TAGS,
                        security: [{ BearerAuth: [], NuidHeader: [] }, { BearerAuth: [] }],
                        schemes: INTERNAL_SCHEMES)
    }
  end

  def frame(title:, description:, tags:, security:, schemes: {})
    {
      openapi:    '3.0.3',
      info:       { title: title, version: '1', description: description },
      servers:    SERVERS,
      security:   security,
      tags:       tags,
      components: {
        securitySchemes: { BearerAuth: BEARER }.merge(schemes),
        responses:       RESPONSES,
        schemas:         OpenapiSchemas.all
      }
    }
  end

  def tag(name, description, page = nil)
    text = page ? "#{description}\n\nBackground: [#{page}](#{DOCS}/#{page})." : description
    { name: name, description: text }
  end

  SERVERS = [
    {
      url:       '{scheme}://{host}',
      variables: {
        scheme: { default: 'https', enum: %w[https http] },
        host:   { default: 'atlas.library.northeastern.edu' }
      }
    }
  ].freeze

  BEARER = {
    type:        :http,
    scheme:      :bearer,
    description: 'A personal access token issued by the repository operator. ' \
                 'Omit the header to call as a guest, who sees public items only.'
  }.freeze

  INTERNAL_SCHEMES = {
    NuidHeader:       {
      type:        :apiKey,
      in:          :header,
      name:        'User',
      description: 'The principal, in the form `NUID <nuid>`. Required with the system token and the ' \
                   'fixity token, and ignored with any other credential.'
    },
    OnBehalfOfHeader: {
      type:        :apiKey,
      in:          :header,
      name:        'On-Behalf-Of',
      description: 'The user a system-token write is attributed to, in the form `NUID <nuid>`. ' \
                   'On a create, the resource reads as a deposit by that user, and the operator is ' \
                   'recorded only in the audit event. Sent with any other credential, it is a 403.'
    }
  }.freeze

  # Shared responses. `Unauthorized` is attached to every operation that
  # accepts a credential, by OpenapiContract; spec/requests/openapi_contract_spec.rb
  # proves each of them answers it. `ServerError` is named here only: a spec
  # cannot provoke a 5xx per path.
  RESPONSES = {
    Unauthorized: {
      description: 'The credential was not recognised: an unknown, expired or revoked token. ' \
                   'Send no `Authorization` header to call as a guest instead.',
      content:     { 'application/json' => { schema: { '$ref' => '#/components/schemas/Error' } } }
    },
    ServerError:  {
      description: 'Atlas, or a proxy in front of it, failed to serve the request. Applies to every ' \
                   'operation. Atlas\'s own 5xx carries an `Error` body; a proxy\'s 502 or 504 can ' \
                   'carry HTML or plain text, so read the status before you parse the body.',
      content:     { 'application/json' => { schema: { '$ref' => '#/components/schemas/Error' } } }
    }
  }.freeze

  PUBLIC_TAGS = [
    tag('Communities', 'The top level of the tree. A Community holds Collections and other Communities.',
        'resource-graph.md'),
    tag('Collections', 'A Collection holds Works and other Collections.', 'resource-graph.md'),
    tag('Works', 'A Work is one deposited item: its metadata, its files and its state.', 'mods.md'),
    tag('FileSets', 'A FileSet groups the files of one asset of a Work, such as a page image and its derivatives.',
        'binaries.md'),
    tag('Files', 'A file is a Blob: one versioned binary in preservation storage.', 'binaries.md'),
    tag('Resources', 'Operations that apply to any resource in the tree, whatever its type.', 'resource-graph.md'),
    tag('Delegates', 'A Delegate points at a derivative that Atlas does not store, such as an image size served by a IIIF server.',
        'binaries.md'),
    tag('Compilations', 'A Compilation is a personal Set of Works and Collections.', 'compilations.md'),
    tag('People', 'A Person is a curatorial identity: a name, a profile and affiliations.', 'people.md'),
    tag('User', 'The calling user, their accounts and the user directory.', 'authentication.md'),
    tag('Maintenance', 'Whether the repository is in a read-only maintenance window.', 'availability.md'),
    tag('Health', 'Whether Atlas can reach its dependencies.', 'availability.md')
  ].freeze

  INTERNAL_TAGS = [
    tag('Maintenance', 'Opening and closing the maintenance window, and the development reset.', 'availability.md'),
    tag('User', 'Provisioning users and minting their tokens.', 'authentication.md'),
    tag('People', 'Creating People and editing their affiliations.', 'people.md'),
    tag('Resources', 'Reindexing, embargo release, fixity and the Solr debug views.', 'solr-indexing.md'),
    tag('Metrics', 'Atlas\'s own request latency figures.', 'read-performance.md')
  ].freeze

  PUBLIC_DESCRIPTION = <<~DESC
    Atlas is the API for the Northeastern University Library digital
    repository (the DRS). It holds the repository's content: the tree of
    Communities, Collections and Works, their descriptive metadata, and their
    files.

    This document is served at `/api-docs/openapi.yaml`, and rendered for
    people at `/docs`.

    ### Getting access

    Without a credential, you are a **guest**. A guest can read public items
    only, and cannot write.

    To read more, or to write, ask the repository operator for a personal
    access token. Send it on every request as `Authorization: Bearer <token>`.
    A token lasts one week, and can be issued read-only. When it expires or
    is revoked, Atlas answers `401`; ask the operator for a new one.

    What a token lets you do depends on the permissions of the user it names.
    An operation that needs more than read access says so in its description.

    ### Errors

    Read the status code first. Every `4xx` and `5xx` that has a body uses
    the `Error` schema, and a client branches on its `error` key, never on
    `message`. Most `404` responses have no body at all.

    Two exceptions are documented where they occur. On some `422` responses,
    `error` is a sentence and the code is in `code`. And a tombstoned
    resource's own record answers `410` with the record, or a stub of it,
    rather than an `Error`.

    Three statuses apply to every operation, so they are not repeated on each
    one:

    - **`503` with `error: "backend_unavailable"`.** Atlas cannot reach a
      dependency. The `dependency` key names it. Wait for the `Retry-After`
      seconds, then retry.
    - **`503` with `error: "read_only_mode"`** on any write. The repository
      is in a maintenance window. `Retry-After` is the expected wait in
      seconds, and can be long; `GET /maintenance` reports the window.
    - **Any `5xx`** (see the `ServerError` response). A proxy in front of
      Atlas can answer `502` or `504` with a body that is not JSON.

    ### Paging

    A list returns one page and a `pagination` block. Ask for another page
    with `?page=<n>`. Lists that take `per_page` cap it at 100.

    The block has one of two shapes. Most lists return `Pagination`: stop
    when `pagination.next` is null. The search-backed lists (search,
    descendant Works and a Compilation's contents) return `SearchPagination`:
    stop when `pagination.page` reaches `pagination.pages`.

    ### Terms

    | Term | Meaning |
    |---|---|
    | NOID | The identifier of a resource in this API: a short, opaque string. Every `id` in a path is a NOID. |
    | NUID | A Northeastern University ID, the 9-digit number that names a person. |
    | Handle | The persistent identifier of a finished Work. It resolves through `https://hdl.handle.net`. |
    | MODS | The library XML standard for descriptive metadata. Atlas keeps each resource's MODS as the preservation copy and serves a JSON reading of it. |
    | METS | The XML standard that describes a Work's files and their structure. |
    | Darwin Core | A metadata standard for biological specimens. A Work can hold one Darwin Core record beside its MODS. |
    | IIIF | The International Image Interoperability Framework. An image FileSet can name a IIIF image service. |
    | Grouper | Northeastern's group directory. A read or edit grant can name a Grouper group as well as a user. |
    | Tombstone | A resource withdrawn from view. Its record stays, but its content is withheld, and reads answer `410`. |
    | Embargo | A date before which a Work's files are withheld from everyone but administrators and repository staff. The Work's record stays readable. |
    | Delegated admin | A user who holds the privileged role and belongs to the admin group. They can restore, reparent and audit, but do not have the full admin role. |
  DESC

  INTERNAL_DESCRIPTION = <<~DESC.freeze
    The operator and backend operations of Atlas. This document is not served:
    it is generated beside the public one so the `atlas_rb` maintainers keep a
    reference, and CI checks it for drift like the public one.

    Every operation here needs the system token, the fixity token or an admin
    credential. The system token and the fixity token each pair with a
    `User: NUID <nuid>` header that names their fixture; see
    [authentication.md](#{DOCS}/authentication.md).

    The error contract, paging and terms are the public document's.
  DESC
end
