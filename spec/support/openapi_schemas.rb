# frozen_string_literal: true

module OpenapiSchemas
  module_function

  # Each schema mirrors a jbuilder partial in app/views/. When a partial
  # changes, the corresponding entry here must change too — strict schema
  # validation in rswag will otherwise fail the request specs.

  # rubocop:disable Metrics/AbcSize -- a flat schema registry that grows by one
  # call per schema; splitting it further hurts readability more than it helps.
  def all
    {
      Work:               work,
      Collection:         collection,
      Community:          community,
      FileSet:            file_set,
      Blob:               blob,
      Delegate:           delegate,
      WorkSummary:        work_summary,
      CollectionSummary:  collection_summary,
      CommunitySummary:   community_summary,
      FileSetSummary:     file_set_summary,
      BlobSummary:        blob_summary,
      WorksIndex:         works_index,
      CollectionsIndex:   collections_index,
      CommunitiesIndex:   communities_index,
      FileSetsIndex:      file_sets_index,
      BlobsIndex:         blobs_index,
      WorkAssets:         work_assets,
      WorkFileSets:       work_file_sets,
      Pagination:         pagination,
      User:               user,
      ProvisionedUser:    provisioned_user,
      UserDirectoryEntry: user_directory_entry,
      UserDirectory:      user_directory,
      UserAccounts:       user_accounts,
      Permissions:        permissions,
      ResourceRef:        resource_ref,
      ResourceDigests:    resource_digests,
      ModsVersions:       mods_versions,
      BlobVersions:       blob_versions,
      BlobAncestry:       blob_ancestry,
      DescendantWorks:    descendant_works,
      WorkAssociations:   work_associations
    }.merge(compilation_schemas).merge(person_schemas)
  end
  # rubocop:enable Metrics/AbcSize

  def person_schemas
    {
      Person:        person,
      PersonSummary: person_summary,
      PeopleIndex:   people_index
    }
  end

  def compilation_schemas
    {
      Compilation:         compilation,
      CompilationSummary:  compilation_summary,
      CompilationsIndex:   compilations_index,
      CompilationContents: compilation_contents
    }
  end

  # ---- detail shapes (one wrapped object) ----

  def work
    wrapped(:work, base_resource_props.merge(work_only_props).merge(
                     derivative_permissions: {
                       type:                 :object,
                       additionalProperties: { type: :array, items: { type: :string } },
                       description:          'Per-asset derivative read policy: sparse map of tier => ' \
                                             '[read groups]. Image ladder small/medium/large/service/' \
                                             'master plus independent media audio/video/pdf. Empty ' \
                                             'when unset (tiers inherit the Work visibility).'
                     }
                   ))
  end

  def collection
    wrapped(:collection, base_resource_props.merge(
                           featured:      { type: :boolean, description: 'Showcase "Featured" flag (genre-showcase Collection)' },
                           personal_root: { type: :boolean, description: "Personal-root flag (a Person's structural workspace container)" }
                         ))
  end

  def community
    wrapped(:community, base_resource_props.merge(
                          system_container: { type: :boolean, description: 'Auto-provisioned structural-container flag (the singleton "People" Community); excluded from discovery' }
                        ))
  end

  def file_set
    wrapped(:file_set, file_set_props)
  end

  # Mirrors file_sets/_file_set_fields.json.jbuilder, which both the wrapped
  # detail payload and the flat index rows render.
  def file_set_props
    {
      id:            { type: :string, description: 'NOID' },
      type:          { type: :string, nullable: true },
      position:      { type: :integer, nullable: true,
                       description: '1-based page order within the parent Work; null = unordered' },
      tombstoned:    { type: :boolean, description: 'Withdrawn-from-discovery flag' },
      tombstoned_at: { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
      tombstoned_by: { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' }
    }
  end

  def blob
    wrapped(:blob, {
              id:                { type: :string, description: 'NOID' },
              mime_type:         { type: :string, nullable: true },
              original_filename: { type: :string, nullable: true },
              use:               { type: :string, nullable: true },
              size:              { type: :integer, nullable: true },
              digest:            { type: :string, nullable: true,
                                   description: 'Fixity digest of the head revision, "<algorithm>:<hexvalue>" (e.g. sha512:…), recorded at ingest from the OCFL inventory' },
              filename:          { type: :string, nullable: true },
              label:             { type: :string, nullable: true },
              file_identifiers:  {
                type:  :array,
                items: { type: :object, additionalProperties: true,
                 description: 'Valkyrie::ID-shaped reference to the underlying bytes' }
              },
              tombstoned:        { type: :boolean, description: 'Withdrawn-from-discovery flag' },
              tombstoned_at:     { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
              tombstoned_by:     { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' }
            })
  end

  # A Delegate is a Blob-shaped resource with no held binary — points
  # at an asset elsewhere via `uri`. Lives as a member of a `:derivative`
  # FileSet to represent sized image variants and similar derivatives.
  def delegate
    wrapped(:delegate, {
              id:                { type: :string, description: 'NOID' },
              valkyrie_id:       { type: :string, description: 'Valkyrie internal id' },
              use:               { type: :string, nullable: true },
              uri:               { type: :string, nullable: true, description: 'Where the asset can be fetched (IIIF URL for image roles)' },
              mime_type:         { type: :string, nullable: true },
              original_filename: { type: :string, nullable: true },
              label:             { type: :string, nullable: true },
              tombstoned:        { type: :boolean, description: 'Withdrawn-from-discovery flag' },
              tombstoned_at:     { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
              tombstoned_by:     { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' }
            })
  end

  # ---- summary shapes (used by index actions) ----

  def work_summary
    bare(summary_props.merge(work_only_props))
  end

  def collection_summary
    bare(summary_props)
  end

  def community_summary
    bare(summary_props)
  end

  # The FileSet index rows carry every detail key (including the tombstone
  # fields) because both render the same fields partial; only the wrapper
  # differs.
  def file_set_summary
    bare(file_set_props)
  end

  def blob_summary
    bare({ id: { type: :string }, use: { type: :string, nullable: true } })
  end

  def person_summary
    bare(person_props)
  end

  def compilation_summary
    bare(compilation_props)
  end

  # ---- collection responses (index) ----

  def works_index
    paged(:works, { '$ref' => '#/components/schemas/WorkSummary' })
  end

  def collections_index
    paged(:collections, { '$ref' => '#/components/schemas/CollectionSummary' })
  end

  def communities_index
    paged(:communities, { '$ref' => '#/components/schemas/CommunitySummary' })
  end

  # Person detail (a wrapped object). Every key is always emitted by the
  # partial (null when absent), so all are required + nullable as appropriate.
  def person
    wrapped(:person, person_props)
  end

  # Mirrors people/_person_fields.json.jbuilder. Every key is always emitted
  # by the partial (null when absent), so all are required + nullable as
  # appropriate.
  def person_props
    {
      id:                       { type: :string, description: 'NOID' },
      valkyrie_id:              { type: :string, description: 'Valkyrie internal id' },
      nuid:                     { type: :string, description: 'Correlation key + public address' },
      display_name:             { type: :string, description: 'Authoritative, librarian-editable name' },
      bio:                      { type: :string, nullable: true },
      orcid:                    { type: :string, nullable: true },
      affiliated_community_ids: { type: :array, items: { type: :string },
                                  description: 'NOIDs of affiliated communities' },
      personal_root_id:         { type: :string, nullable: true,
                                  description: "NOID of the Person's personal-root Collection " \
                                               "(the publish conduit's structural parent)" }
    }
  end

  # People index / batch-resolve. Always paginated for a uniform shape (the
  # ?nuids batch returns all matches in one page — page size = match count).
  def people_index
    paged(:people, { '$ref' => '#/components/schemas/PersonSummary' })
  end

  def file_sets_index
    paged(:file_sets, { '$ref' => '#/components/schemas/FileSetSummary' })
  end

  def blobs_index
    paged(:blobs, { '$ref' => '#/components/schemas/BlobSummary' })
  end

  # ---- specialized shapes ----

  # GET /works/:id/assets — polymorphic array of downloadable assets attached
  # to a Work. Mirrors app/views/works/assets.json.jbuilder: each item is
  # shaped after its underlying model (Blob = held binary; Delegate =
  # pointer-only). Thumbnails (Role.thumbnail_image) and metadata roles
  # are excluded by Role.downloadable?.
  def work_assets
    {
      type:  :array,
      items: asset_item
    }
  end

  # Polymorphic per-asset item shared by WorkAssets (flattened) and
  # WorkFileSets (grouped per page) — mirrors the shared
  # works/_asset.json.jbuilder partial.
  def asset_item
    {
      oneOf: [
        {
          type:        :object,
          properties:  {
            noid:              { type: :string },
            mime_type:         { type: :string, nullable: true },
            original_filename: { type: :string, nullable: true },
            size:              { type: :integer, nullable: true },
            filename:          { type: :string, nullable: true },
            label:             { type: :string, nullable: true },
            role:              { type: :string, nullable: true, description: 'Stable machine token for the asset role — the Role key (e.g. service_file, small_image, original_file). Match on this, not the human `use` label' },
            classification:    { type: :string, nullable: true,
                                 description: 'Classification name of the containing FileSet (Image/PDF/Structured Text/…; "File" = unidentified). Download consumers key on "File" to zip opaque binaries on the fly' },
            gated:             { type:        :boolean,
                                 description: 'True if this binary must be authorized rather than downloaded directly (its audience is not public). Blobs classify by media type: image original => master, plus pdf/audio/video; other types ride the Work gate' },
            permission:        { type: :array, items: { type: :string }, nullable: true,
                                 description: 'Effective read-group set gating this binary (public / Grouper groups / [] private); null for guests, to whom group names are not disclosed' }
          },
          required:    %w[noid],
          description: 'Blob asset — held binary'
        },
        {
          type:        :object,
          properties:  {
            noid:       { type: :string },
            mime_type:  { type: :string, nullable: true },
            use:        { type: :string, nullable: true, description: 'Human display label for the role (e.g. "Service File"); match on `role` for a stable token' },
            uri:        { type: :string, nullable: true },
            label:      { type: :string, nullable: true },
            role:       { type: :string, nullable: true, description: 'Stable machine token for the asset role — the Role key (e.g. service_file, small_image). Match on this, not the human `use` label' },
            classification: { type: :string, nullable: true,
                              description: 'Classification name of the containing FileSet (e.g. Derivative for IIIF tiers)' },
            gated:      { type:        :boolean,
                          description: 'True if this derivative tier must be authorized rather than linked directly (its audience is not public)' },
            permission: { type: :array, items: { type: :string }, nullable: true,
                          description: 'Effective read-group set gating this tier (public / Grouper groups / [] private); null for guests, to whom group names are not disclosed' }
          },
          required:    %w[noid],
          description: 'Delegate asset — external pointer (e.g. IIIF URL)'
        }
      ]
    }
  end

  # GET /works/:id/file_sets — ordered page listing for multipage Works.
  # One entry per page-bearing FileSet (metadata and :derivative FileSets
  # excluded), position ASC with nulls last, each carrying its downloadable
  # assets. Unpaginated by design: manifest assembly needs the whole
  # sequence in one read.
  def work_file_sets
    {
      type:  :array,
      items: {
        type:       :object,
        properties: {
          noid:       { type: :string, description: 'NOID of the FileSet' },
          type:       { type: :string, nullable: true, description: 'Classification name' },
          position:   { type: :integer, nullable: true,
                        description: '1-based page order; null = unordered (sorted last)' },
          tombstoned: { type: :boolean, description: 'Withdrawn-from-discovery flag' },
          assets:     { type: :array, items: asset_item }
        },
        required:   %w[noid type position tombstoned assets]
      }
    }
  end

  # Compilation (DRS "Set") — AR-tier personal curation record, mirrors
  # compilations/_compilation.json.jbuilder. `id` is the minted NOID; the
  # AR pk is never exposed.
  def compilation
    wrapped(:compilation, compilation_props)
  end

  # Mirrors compilations/_compilation_fields.json.jbuilder, which both the
  # wrapped show payload and the flat index rows render.
  def compilation_props
    {
      id:          { type: :string, description: 'NOID (minted; the API-addressable id)' },
      title:       { type: :string },
      description: { type: :string, nullable: true },
      depositor:   { type: :string, description: 'Curator NUID (owner)' },
      published:   { type:        :boolean,
                     description: 'OAI-PMH set flag: when true the Set is listed by ' \
                                  'GET /oai?verb=ListSets and harvesters may walk it' }
    }.merge(compilation_recipe_props, compilation_acl_props)
  end

  # The three noid arrays are the raw recipe — resolved by GET
  # /compilations/{id}/contents, not materialized on the record.
  def compilation_recipe_props
    {
      included_collections: { type:        :array, items: { type: :string },
                              description: 'Collection noids included transitively (self + descendants)' },
      included_works:       { type:        :array, items: { type: :string },
                              description: 'Work noids included individually' },
      excluded_works:       { type:        :array, items: { type: :string },
                              description: 'Work noids set aside (subtracted from the resolved union)' }
    }
  end

  def compilation_acl_props
    {
      edit_users:  { type: :array, items: { type: :string } },
      read_groups: { type: :array, items: { type: :string } },
      edit_groups: { type: :array, items: { type: :string } },
      created_at:  { type: :string, format: 'date-time' },
      updated_at:  { type: :string, format: 'date-time' }
    }
  end

  def compilations_index
    paged(:compilations, { '$ref' => '#/components/schemas/CompilationSummary' })
  end

  # GET /compilations/{id}/contents — the resolved recipe as find_many-style
  # digests (mirrors compilations/contents.json.jbuilder). Pagination is
  # Solr-side: { total, page, per_page, pages }.
  def compilation_contents
    {
      type:       :object,
      properties: {
        contents:   { type: :array, items: work_digest },
        pagination: { '$ref' => '#/components/schemas/Pagination' }
      },
      required:   %w[contents pagination]
    }
  end

  # GET /resources/{id}/descendant_works — the structural subtree flattened to
  # Work digests (mirrors resources/descendant_works.json.jbuilder). Same
  # digest + pagination shape as compilation_contents, under a `works` key.
  def descendant_works
    {
      type:       :object,
      properties: {
        works:      { type: :array, items: work_digest },
        pagination: { '$ref' => '#/components/schemas/Pagination' }
      },
      required:   %w[works pagination]
    }
  end

  # GET/POST/DELETE /works/{id}/associations — the typed Work-to-Work edges
  # (mirrors works/associations.json.jbuilder). Both maps are keyed by
  # predicate and hold NOIDs; a predicate with no edges is omitted, so the
  # properties stay open rather than enumerated.
  def work_associations
    {
      type:       :object,
      properties: {
        outbound: work_association_map('What this Work asserts about other Works'),
        inbound:  work_association_map('What other Works assert about this one')
      },
      required:   %w[outbound inbound]
    }
  end

  def work_association_map(description)
    {
      type:                 :object,
      description:          description,
      additionalProperties: { type: :array, items: { type: :string } }
    }
  end

  # The find_many-style Work digest shared by /compilations/{id}/contents and
  # /resources/{id}/descendant_works (both resolve containers to Works via the
  # WorkDigestQuery engine).
  def work_digest
    {
      type:       :object,
      properties: {
        id:        { type: :string, description: 'NOID' },
        noid:      { type: :string, description: 'NOID (same value as id; find_many digest parity)' },
        klass:     { type: :string, description: 'Resolved resource class name (always Work here)' },
        title:     { type: :string, nullable: true, description: 'Plain-text title off the Solr doc' },
        thumbnail: { type: :string, nullable: true, description: 'IIIF URL of the thumbnail tier, or null' }
      },
      required:   %w[id noid klass title thumbnail]
    }
  end

  def pagination
    {
      type:                 :object,
      description:          'pagy pagination block',
      additionalProperties: true
    }
  end

  # GET /user uses `render :json => current_user.to_json` so the response is
  # the AR record's default JSON serialization (id, email, name, role, …),
  # *not* the jbuilder envelope. Permissive schema documents the shape
  # without pinning every Devise/AR field.
  def user
    {
      type:                 :object,
      description:          'Devise/AR User record serialized via to_json. Fields vary; commonly includes id, nuid, email, name, role, groups, affiliation, preferred.',
      properties:           {
        id:          { type: :integer },
        nuid:        { type: :string, nullable: true },
        email:       { type: :string, nullable: true },
        name:        { type: :string, nullable: true },
        role:        { type: :string, nullable: true },
        affiliation: { type: :string, nullable: true, description: 'This login\'s unscoped-affiliation, a human label for the account' },
        preferred:   { type: :boolean, description: 'Whether this is the default account for its NUID' }
      },
      additionalProperties: true
    }
  end

  # PUT /users/by_email/{email} (and the by_nuid shim) — strict shape pinned to
  # the response partial at app/views/users/_user.json.jbuilder. Distinct from
  # the permissive `User` schema above, which documents the AR `to_json` output
  # of GET /user.
  def provisioned_user
    wrapped(:user, {
              id:          { type: :integer },
              nuid:        { type: :string, nullable: true },
              name:        { type: :string, nullable: true },
              email:       { type: :string, nullable: true },
              role:        { type: :string },
              groups:      { type: :array, items: { type: :string } },
              affiliation: { type: :string, nullable: true },
              preferred:   { type: :boolean }
            })
  end

  # GET /users/by_nuid/{nuid}/accounts — every account sharing a NUID, pinned
  # to users/accounts.json.jbuilder. Unlike the minimal directory entry this
  # discloses each account's email, affiliation, role, groups, and preferred
  # flag (self/admin/system-gated).
  def user_accounts
    {
      type:       :object,
      properties: {
        nuid:     { type: :string },
        accounts: {
          type:  :array,
          items: {
            type:       :object,
            properties: {
              email:       { type: :string },
              name:        { type: :string, nullable: true },
              affiliation: { type: :string, nullable: true },
              role:        { type: :string },
              groups:      { type: :array, items: { type: :string } },
              preferred:   { type: :boolean }
            },
            required:   %w[email name affiliation role groups preferred]
          }
        }
      },
      required:   %w[nuid accounts]
    }
  end

  # GET /users/by_nuid/{nuid} (and each GET /users item) — minimal-
  # disclosure directory entry pinned to users/_directory_entry.json.jbuilder:
  # nuid + name only, never email/role/groups.
  def user_directory_entry
    {
      type:       :object,
      properties: {
        nuid: { type: :string },
        name: { type: :string, nullable: true }
      },
      required:   %w[nuid name]
    }
  end

  # GET /users — flat capped array (typeahead search or batch resolve),
  # no pagination envelope.
  def user_directory
    {
      type:  :array,
      items: { '$ref' => '#/components/schemas/UserDirectoryEntry' }
    }
  end

  def permissions
    wrapped(:resource, {}, additional:  true,
                           description: 'Permission flags merged from Resource#permissions')
  end

  # GET /resources/:id can return any of these shapes — the controller
  # delegates based on the resolved class.
  def resource_ref
    {
      oneOf: [
        { '$ref' => '#/components/schemas/Work' },
        { '$ref' => '#/components/schemas/Collection' },
        { '$ref' => '#/components/schemas/Community' },
        { '$ref' => '#/components/schemas/FileSet' },
        { '$ref' => '#/components/schemas/Delegate' }
      ]
    }
  end

  # POST /resources/find_many returns one lightweight digest per resolved
  # resource. Unordered, and may be shorter than the requested id list
  # (unresolvable ids are dropped). title/thumbnail are null for resources
  # off the Modsable backbone (FileSet/Blob).
  def resource_digests
    {
      type:  :array,
      items: {
        type:       :object,
        properties: {
          id:         { type: :string, description: 'NOID' },
          noid:       { type: :string, description: 'NOID (same value as id; explicit for batch callers indexing by noid)' },
          klass:      { type: :string, description: 'Resolved resource class name' },
          title:      { type: :string, nullable: true, description: 'Plain-text title; null off the Modsable backbone' },
          thumbnail:  { type: :string, nullable: true, description: 'IIIF URL of the thumbnail tier, or null' },
          tombstoned: { type: :boolean, description: 'Withdrawn-from-discovery flag — kept in the result but flagged' }
        },
        required:   %w[id noid klass title thumbnail tombstoned]
      }
    }
  end

  # ---- helpers ----

  def base_resource_props
    {
      id:            { type: :string, description: 'NOID' },
      valkyrie_id:   { type: :string, description: 'Valkyrie internal id' },
      ancestors:     ancestor_nodes,
      thumbnail:     { type: :string, nullable: true, description: 'IIIF URL of the :thumbnail_image Delegate (~85px), or null' },
      thumbnail_2x:  { type: :string, nullable: true, description: 'IIIF URL of the :thumbnail_image_2x Delegate (~170px retina), or null' },
      preview:       { type: :string, nullable: true, description: 'IIIF URL of the :preview_image Delegate (~500px hero), or null' },
      title:         { type: :string, nullable: true },
      description:   { type: :string, nullable: true },
      permanent_url: { type: :string, nullable: true },
      tombstoned:    { type: :boolean, description: 'Withdrawn-from-discovery flag' },
      tombstoned_at: { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
      tombstoned_by: { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' }
    }.merge(provenance_props)
  end

  # Resource-level provenance fields surfaced by Work / Collection /
  # Community show responses. Pulled out so base_resource_props stays
  # within the MethodLength budget; mirrors how `work_only_props` is
  # split out for Work-specific keys.
  def provenance_props
    {
      depositor:      { type: :string, nullable: true, description: 'NUID of the intellectual owner (the named depositor; may differ from the hands-on-keyboard actor)' },
      proxy_uploader: { type: :string, nullable: true, description: 'NUID of the hands-on-keyboard actor for the most-recent create. Equals depositor for self-deposit; differs in the librarian-on-behalf (proxy-deposit) case. Left null under acting-as impersonation (On-Behalf-Of header present) — the operator is recorded only in the AuditEvent, not on the resource.' }
    }
  end

  # ancestors is the chain root-first, each node an object carrying the
  # ancestor's title under named keys — so breadcrumb consumers get the title
  # without a per-ancestor round-trip.
  def ancestor_nodes
    {
      type:        :array,
      description: 'Ancestor chain, root-first, with titles — array of {noid, klass, title} objects',
      items:       {
        type:       :object,
        properties: {
          noid:  { type: :string, description: 'Ancestor NOID' },
          klass: { type: :string, description: 'Ancestor resource class name' },
          title: { type: :string, description: 'Ancestor plain-text title (may be empty)' }
        },
        required:   %w[noid klass title]
      }
    }
  end

  # GET /resources/:id/mods/versions — MODS version-history envelope. Field
  # names mirror the AuditEvent descriptor so a consumer can render this
  # stream with the same helpers it uses for /history. Reverse-chronological.
  # Actor fields are correlated from the audit log and are null when no edit
  # event matches the version (e.g. the seed version a resource is born with).
  def mods_versions
    {
      type:       :object,
      properties: {
        resource_id: { type: :string, description: 'NOID of the resource' },
        versions:    {
          type:  :array,
          items: {
            type:       :object,
            properties: {
              version_id:        { type: :string, description: 'OCFL version label (vN); stable and sortable' },
              created:           { type: :string, format: 'date-time', description: 'OCFL version creation timestamp (ISO-8601)' },
              actor_nuid:        { type: :string, nullable: true, description: 'Editing NUID, correlated from the audit log; null when uncorrelatable' },
              on_behalf_of_nuid: { type: :string, nullable: true, description: 'Impersonation target NUID from the correlated event; usually null' },
              source:            { type: :string, nullable: true, description: "Edit source from the correlated event: 'mods' (full doc) or 'fields' (field patch)" },
              note:              { type: :string, nullable: true, description: 'Optional rationale from the correlated event' }
            },
            required:   %w[version_id created actor_nuid on_behalf_of_nuid source note]
          }
        }
      },
      required:   %w[resource_id versions]
    }
  end

  # GET /files/:id/versions — binary version-history envelope. The counterpart
  # to ModsVersions: one descriptor per retained content revision (off the
  # Blob's file_identifiers), reverse-chronological. created/digest/size come
  # from the OCFL inventory; actor fields are correlated from the file audit
  # ledger and null when no event matches (e.g. a back-loaded Blob).
  def blob_versions
    {
      type:       :object,
      properties: {
        blob_id:  { type: :string, description: 'NOID of the Blob' },
        versions: {
          type:  :array,
          items: {
            type:       :object,
            properties: {
              revision:          { type: :integer, description: 'Contiguous 1-based content-revision ordinal (the primary label); revision 1 is the seed. Never skips, unlike version_id.' },
              version_id:        { type: :string, description: 'Raw OCFL version label (vN); secondary/debug. Can jump (v1 → v4) because preservation-envelope bumps consume OCFL versions.' },
              file_identifier:   { type: :string, description: 'Versioned Valkyrie::ID appended for this revision' },
              created:           { type: :string, format: 'date-time', description: 'OCFL version creation timestamp (ISO-8601)' },
              actor_nuid:        { type: :string, nullable: true, description: 'NUID that wrote this revision, correlated from the file audit log; null when uncorrelatable' },
              on_behalf_of_nuid: { type: :string, nullable: true, description: 'Impersonation target NUID from the correlated event; usually null' },
              digest:            { type: :string, nullable: true, description: 'Fixity as recorded at that version, "<algorithm>:<hexvalue>"' },
              size:              { type: :integer, nullable: true, description: 'Byte size of this revision' },
              original_filename: { type: :string, nullable: true, description: 'Stable original filename (preserved across revisions)' }
            },
            required:   %w[revision version_id file_identifier created actor_nuid on_behalf_of_nuid digest size original_filename]
          }
        }
      },
      required:   %w[blob_id versions]
    }
  end

  # GET /files/:id/ancestry — resolve a content Blob to its parent FileSet and
  # parent Work noids. Flat so a consumer can roll a download impression up to
  # its containing Work from the blob id alone. Either value is null when
  # unresolvable (orphan blob, or a non-content blob whose ancestor isn't a
  # FileSet/Work).
  def blob_ancestry
    {
      type:       :object,
      properties: {
        file_set: { type: :string, nullable: true, description: 'NOID of the parent FileSet; null when unresolvable' },
        work:     { type: :string, nullable: true, description: 'NOID of the containing Work; null when unresolvable' }
      },
      required:   %w[file_set work]
    }
  end

  def summary_props
    {
      id:          { type: :string },
      title:       { type: :string, nullable: true },
      description: { type: :string, nullable: true }
    }
  end

  # Fields that live on Work but not on Collection/Community.
  def work_only_props
    {
      in_progress:       { type:        :boolean,
                           description: 'Cerberus-driven workflow flag; true until the bulk-deposit job marks the Work complete.' },
      incomplete:        { type:        :boolean,
                           description: 'Pipeline-failure flag; true when a work-scoped enrichment job gave up ' \
                                        'after its retries. Flags only — the Work stays readable.' },
      incomplete_reason: { type: :string, nullable: true,
                           description: 'Machine token naming the cause (e.g. pdf_rendition_gave_up). Opaque to ' \
                                        'Atlas and unvalidated; the vocabulary belongs to the caller. Null unless ' \
                                        'the Work is flagged.' },
      handle:            { type: :string, nullable: true,
                           description: 'Persistent identifier, "<prefix>/<noid>", minted against the Handle ' \
                                        'service when the Work is finalized. Null until then, and on any ' \
                                        'deployment with no handle server configured.' }
    }
  end

  # An unwrapped property block, every key required because the partial always
  # emits it. A single resource is wrapped in its type name; a row inside a
  # named collection is not, so index rows use this directly.
  def bare(properties, additional: false, description: nil)
    schema = { type: :object, properties: properties, required: properties.keys.map(&:to_s) }
    schema[:additionalProperties] = true if additional
    schema[:description] = description if description
    schema
  end

  # Wrap a property block under a single key (matches jbuilder `json.work do ... end`).
  def wrapped(key, properties, additional: false, description: nil)
    {
      type:       :object,
      properties: { key => bare(properties, additional: additional, description: description) },
      required:   [key.to_s]
    }
  end

  # Paged collection: wrap an array under a key alongside the pagination block.
  def paged(key, item_schema)
    {
      type:       :object,
      properties: {
        key => { type: :array, items: item_schema },
        pagination: { '$ref' => '#/components/schemas/Pagination' }
      },
      required:   [key.to_s, 'pagination']
    }
  end
end
