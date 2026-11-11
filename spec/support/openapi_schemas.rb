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
      Work:                    work,
      Collection:              collection,
      Community:               community,
      FileSet:                 file_set,
      Blob:                    blob,
      Delegate:                delegate,
      WorkSummary:             work_summary,
      CollectionSummary:       collection_summary,
      CommunitySummary:        community_summary,
      FileSetSummary:          file_set_summary,
      BlobSummary:             blob_summary,
      WorksIndex:              works_index,
      CollectionsIndex:        collections_index,
      CommunitiesIndex:        communities_index,
      FileSetsIndex:           file_sets_index,
      BlobsIndex:              blobs_index,
      WorkAssets:              work_assets,
      WorkFileSets:            work_file_sets,
      TombstonedAssets:        work_tombstoned_assets,
      WorkFileRevisions:       work_file_revisions,
      WorkHealthCheck:         work_health_check,
      FixityCheck:             fixity_check,
      FixityDue:               fixity_due,
      Error:                   error,
      Pagination:              pagination,
      SearchPagination:        search_pagination,
      User:                    user,
      ProvisionedUser:         provisioned_user,
      UserDirectoryEntry:      user_directory_entry,
      UserDirectory:           user_directory,
      UserAccounts:            user_accounts,
      Permissions:             permissions,
      ResourceRef:             resource_ref,
      ResourceDigests:         resource_digests,
      ModsVersions:            mods_versions,
      WorkMods:                work_mods,
      Citation:                citation,
      CollectionMods:          container_mods(:collection),
      CommunityMods:           container_mods(:community),
      ResourceMods:            resource_mods,
      WorkMets:                mets(:work),
      FileSetMets:             mets(:file_set),
      WorkDarwinCore:          work_darwin_core,
      BlobVersions:            blob_versions,
      BlobVersionsBatch:       blob_versions_batch,
      BlobAncestry:            blob_ancestry,
      DescendantWorks:         descendant_works,
      SearchResults:           search_results,
      IndexDocument:           index_document,
      SearchExplanation:       search_explanation,
      WorkAssociations:        work_associations,
      MaintenanceMode:         maintenance_mode,
      Health:                  health,
      Latency:                 latency,
      EmbargoRelease:          embargo_release,
      Tombstoned:              tombstoned_error,
      TombstoneReason:         tombstone_reason,
      BlobAsset:               blob_asset,
      DelegateAsset:           delegate_asset,
      TombstonedBlobAsset:     tombstoned_asset(blob_asset),
      TombstonedDelegateAsset: tombstoned_asset(delegate_asset)
    }.merge(compilation_schemas).merge(person_schemas).merge(tombstone_stub_schemas)
  end
  # rubocop:enable Metrics/AbcSize

  # The record a tombstoned Work or container answers below the operator tiers.
  # Mirrors resources/tombstone.json.jbuilder.
  def tombstone_stub_schemas
    purged_stub_schemas.merge(tombstoned_stub_schemas)
  end

  # The record a purged Work or container answers to every caller. Mirrors
  # resources/purged.json.jbuilder.
  def purged_stub_schemas
    %i[work collection community].to_h do |key|
      [:"#{key.to_s.capitalize}Purged", wrapped(key, {
                                                  id:        { type: :string, description: 'NOID' },
                                                  purged:    { type: :boolean, enum: [true] },
                                                  purged_at: { type: :string, format: 'date-time' }
                                                })]
        .then { |name, schema| [name, close_stub(schema, key)] }
    end
  end

  def tombstoned_stub_schemas
    %i[work collection community].to_h do |key|
      [:"#{key.to_s.capitalize}Tombstone", wrapped(key, {
                                                     id:               { type: :string, description: 'NOID' },
                                                     title:            { type: :string, nullable: true },
                                                     permanent_url:    { type: :string, nullable: true },
                                                     tombstoned:       { type: :boolean, enum: [true] },
                                                     tombstoned_at:    { type: :string, nullable: true },
                                                     tombstone_reason: tombstone_reason_prop
                                                   })]
        .then { |name, schema| [name, close_stub(schema, key)] }
    end
  end

  # A stub carries only its own keys, so it cannot also match the full record:
  # the three 410 shapes of a resource are then mutually exclusive.
  def close_stub(schema, key)
    schema.deep_merge(properties: { key => { additionalProperties: false } })
  end

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

  # GET/PUT /maintenance — the repository-wide read-only window. Unwrapped: it is
  # a single flag, not a resource with a type name.
  def maintenance_mode
    bare({
           read_only:   { type: :boolean, description: 'Whether writes are currently refused' },
           source:      { type: :string, nullable: true, enum: ['operator', 'deploy', nil], description: 'Which door opened the window; null when closed' },
           since:       { type: :string, format: :'date-time', nullable: true, description: 'When the window opened; null when closed' },
           message:     { type: :string, nullable: true, description: 'Operator note for the client-side banner' },
           retry_after: { type: :integer, description: 'Seconds a refused caller should wait; mirrored into the 503 Retry-After header' }
         })
  end

  # GET /health. Values only, never hosts or error text: the endpoint is
  # unauthenticated.
  def health
    dependency = { type: :string, enum: %w[ok unavailable] }
    bare({
           status:   { type: :string, enum: %w[ok degraded unavailable],
                       description: '`unavailable` when the database is down, `degraded` when anything else is' },
           database: dependency.merge(description: 'Postgres answers a query'),
           index:    dependency.merge(description: 'The Solr core answers a ping'),
           storage:  dependency.merge(description: 'Every OCFL storage root is a writable directory, and the first ' \
                                                   'carries the OCFL marker once anything is deposited'),
           cache:    { type: :string, enum: %w[ok unavailable disabled],
                       description: 'Redis answers a ping; `disabled` when no Redis cache is configured. ' \
                                    'Never makes the status 503, because reads fall back to rendering' }
         })
  end

  # GET /metrics/latency. Percentiles are interpolated from histogram buckets,
  # so they are approximate.
  def latency
    ms = { type: :integer, nullable: true }
    bare({
           window_minutes:  { type: :integer, description: 'The minutes the figures cover, up to 120' },
           calls:           { type: :integer, description: 'Requests Atlas served in the window' },
           server_errors:   { type: :integer, description: 'Of those, the ones answered 5xx' },
           mean_ms:         ms.merge(description: 'Mean duration; null when there were no calls'),
           p50_ms:          ms.merge(description: 'Approximate median, interpolated from the histogram'),
           p95_ms:          ms.merge(description: 'Approximate 95th percentile'),
           p99_ms:          ms.merge(description: 'Approximate 99th percentile'),
           slowest_actions: { type: :array, description: 'Up to ten controller actions, slowest p95 first',
                              items: bare({ action: { type: :string, description: '`controller#action`' },
                                            calls:  { type: :integer },
                                            p95_ms: { type: :integer } }) }
         })
  end

  def embargo_release
    bare({
           released: { type: :array, items: { type: :string },
                       description: 'NOIDs of the Works that gained an Embargo released row on this call' }
         })
  end

  # ---- detail shapes (one wrapped object) ----

  def work
    wrapped(:work, base_resource_props.merge(work_only_props).merge(
                     derivative_permissions: {
                       type:                 :object,
                       additionalProperties: { type: :array, items: { type: :string } },
                       description:          'Per-asset derivative read policy: sparse map of tier => ' \
                                             '[read groups]. Image ladder small/medium/large/service/' \
                                             'original plus independent tiers audio/video/pdf/archive/' \
                                             'spreadsheet/structured_text/presentation/text/generic. Empty ' \
                                             'when unset (tiers inherit the Work visibility). For a guest each ' \
                                             'tier keeps only `public`, so a reserved tier reads [].'
                     },
                     embargoed:              {
                       type:        :boolean,
                       description: 'Whether an active embargo withholds the Work\'s files now. Its record stays readable.'
                     },
                     embargo_release_date:   {
                       type: :string, format: 'date-time', nullable: true,
                       description: 'When the embargo ends, past or future; null when the Work has none.'
                     },
                     metadata_formats:       {
                       type:        :array,
                       items:       { type: :string, enum: MetadataRecords::SOURCES },
                       description: 'The additional metadata records the Work holds, e.g. "dwc" for Darwin ' \
                                    'Core. Empty when it holds none. MODS and METS are never listed.'
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
      id:               { type: :string, description: 'NOID' },
      type:             { type: :string, nullable: true },
      position:         { type: :integer, nullable: true,
                       description: '1-based page order within the parent Work; null = unordered' },
      tombstoned:       { type: :boolean, description: 'Tombstoned (suppressed from discovery) flag' },
      tombstoned_at:    { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
      tombstoned_by:    { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' },
      tombstone_reason: tombstone_reason_prop,
      updated_at:       updated_at_prop
    }
  end

  # When the record itself last changed. docs/openapi.md says what moves it.
  def updated_at_prop
    { type: :string, format: 'date-time', nullable: true,
      description: 'When this record last changed: its metadata, permissions or state. Adding or replacing ' \
                   'a file changes the file\'s own record, not its Work\'s.' }
  end

  def blob
    wrapped(:blob, {
              id:                       { type: :string, description: 'NOID' },
              mime_type:                { type: :string, nullable: true },
              original_filename:        { type: :string, nullable: true },
              use:                      { type: :string, nullable: true },
              size:                     { type: :integer, nullable: true },
              digest:                   { type: :string, nullable: true,
                                   description: 'Fixity digest of the head revision, "<algorithm>:<hexvalue>" (e.g. sha512:…), recorded at ingest from the OCFL inventory' },
              filename:                 { type: :string, nullable: true },
              label:                    { type: :string, nullable: true },
              language:                 { type: :string, nullable: true, description: 'BCP 47 language of a caption or other text track (e.g. en, es-MX)' },
              track_label:              { type: :string, nullable: true, description: 'Display name a player shows for the track (e.g. "Español")' },
              file_identifiers:         {
                type:        :array,
                items:       { type: :object, additionalProperties: true,
                               description: 'Valkyrie::ID-shaped reference to the underlying bytes' },
                description: 'Where the bytes sit in OCFL storage. Empty for a guest.'
              },
              tombstoned:               { type: :boolean, description: 'Tombstoned (suppressed from discovery) flag' },
              tombstoned_at:            { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
              tombstoned_by:            { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' },
              updated_at:               updated_at_prop,
              tombstoned_in_effect:     { type:        :boolean,
                                          description: 'True when the Blob, its FileSet or its Work is tombstoned. ' \
                                                       'Its content is then withheld below the operator tiers' },
              tombstoned_resource_id:   { type: :string, nullable: true,
                                          description: 'NOID of the resource whose tombstone applies; null when none does' },
              tombstoned_resource_type: { type: :string, nullable: true,
                                          description: 'Type of the resource whose tombstone applies' }
            })
  end

  # A Delegate is a Blob-shaped resource with no held binary — points
  # at an asset elsewhere via `uri`. Lives as a member of a `:derivative`
  # FileSet to represent sized image variants and similar derivatives.
  def delegate
    wrapped(:delegate, {
              kind:              { type: :string, enum: %w[Delegate], description: 'The asset model, as the asset listings name it' },
              id:                { type: :string, description: 'NOID' },
              valkyrie_id:       { type: :string, description: 'Valkyrie internal id' },
              use:               { type: :string, nullable: true },
              uri:               { type: :string, nullable: true,
                                 description: 'Where the asset can be fetched (IIIF URL for image roles). Null for the ' \
                                              'gated small, medium, large and service roles while an embargo withholds them ' \
                                              'from the caller: below staff, without an edit grant on the Work.' },
              mime_type:         { type: :string, nullable: true },
              original_filename: { type: :string, nullable: true },
              label:             { type: :string, nullable: true },
              tombstoned:        { type: :boolean, description: 'Tombstoned (suppressed from discovery) flag' },
              tombstoned_at:     { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
              tombstoned_by:     { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' },
              updated_at:        updated_at_prop
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

  # GET /works/:id/tombstoned_assets — the WorkAssets item for a tombstoned
  # FileSet, plus the FileSet's tombstone stamp. Mirrors
  # app/views/works/tombstoned_assets.json.jbuilder.
  def work_tombstoned_assets
    { type: :array, items: asset_item('Tombstoned') }
  end

  def tombstoned_asset(branch)
    branch.merge(properties: branch[:properties].merge(tombstone_stamp))
  end

  def tombstone_stamp
    {
      tombstoned_at: { type: :string, nullable: true, description: 'ISO-8601 timestamp the FileSet was tombstoned' },
      tombstoned_by: { type: :string, nullable: true, description: 'NUID of the user who tombstoned the FileSet' }
    }
  end

  # GET /works/:id/health_check. Mirrors app/views/works/health_check.json.jbuilder.
  # `code` is an open vocabulary: a client shows an unknown one rather than
  # failing on it. docs/work-health.md lists the codes.
  def work_health_check
    {
      type:       :object,
      required:   %w[noid grade fixity_checked fixity findings],
      properties: {
        noid:           { type: :string },
        grade:          { type: :string, enum: %w[green yellow red],
                          description: 'green viable; yellow repairable, nothing lost; red bytes lost' },
        fixity_checked: { type: :boolean, description: 'Always false: this endpoint never re-hashes the bytes' },
        fixity:         work_fixity_summary,
        findings:       { type: :array, items: health_finding }
      }
    }
  end

  # The recorded checks over the objects a Work reaches, never a re-hash.
  def work_fixity_summary
    bare({
           last_checked_at: { type: :string, format: 'date-time', nullable: true,
                              description: 'The oldest latest check among the objects; null while any is unchecked' },
           result:          { type: :string, enum: [*FixityResult::RESULTS, nil], nullable: true,
                              description: 'The worst recorded outcome among the objects, or null when none is recorded' },
           objects:         { type: :integer, description: 'The OCFL objects the Work reaches' },
           never_checked:   { type: :integer, description: 'Objects with no recorded check' }
         })
  end

  # POST /fixity_checks. Mirrors app/views/fixity_checks/create.json.jbuilder.
  def fixity_check
    wrapped(:fixity_check, {
              resource_id: { type: :string, description: 'NOID of the resource that owns the object' },
              object:      { type: :string, description: 'The OCFL inventory id, urn:neu-drs:<noid>' },
              checked_at:  { type: :string, format: 'date-time', description: 'When the check ran, to the second' },
              version:     { type: :string, description: 'The object version checked, e.g. v3' },
              algorithm:   { type: :string, enum: FixityCheck::ALGORITHMS },
              files:       { type: :integer, description: 'Files re-hashed' },
              result:      { type: :string, enum: FixityResult::RESULTS },
              findings:    { type: :array, items: fixity_finding },
              checker:     { type: :string, description: 'The tool that ran the check' },
              recorded_by: { type: :string, nullable: true, description: 'NUID of the principal that posted it' },
              latest:      { type: :boolean, description: "Whether this is now the object's latest check" }
            })
  end

  # GET /fixity_checks/due. Mirrors app/views/fixity_checks/due.json.jbuilder.
  def fixity_due
    bare({
           due: { type: :array, items: bare({
                                              key:             { type: :string, description: 'The object key (the NOID)' },
                                              object:          { type: :string, description: 'urn:neu-drs:<noid>' },
                                              bytes:           { type: :integer, description: 'Bytes on disk, from the storage ledger' },
                                              last_checked_at: { type: :string, format: 'date-time', nullable: true,
                                                                 description: 'The latest recorded check, or null' }
                                            }) }
         })
  end

  def fixity_finding
    {
      type:       :object,
      required:   %w[code],
      properties: FixityCheck::FINDING_KEYS.to_h { |key| [key.to_sym, { type: :string }] }
    }
  end

  def health_finding
    {
      type:       :object,
      required:   %w[severity code subject message],
      properties: {
        severity: { type: :string, enum: %w[advisory repairable fatal] },
        code:     { type: :string, description: 'Machine-readable finding, such as mods_xml_missing' },
        subject:  { type: :string, description: 'NOID of the object the finding is about' },
        message:  { type: :string }
      }
    }
  end

  # The two branches of the polymorphic asset item, as components so a
  # discriminator on `kind` can name them.
  def blob_asset
    {
      type:        :object,
      properties:  {
        kind:              { type: :string, enum: %w[Blob],
                             description: 'The asset model. Match on this to tell a Blob from a Delegate' },
        noid:              { type: :string },
        file_set:          { type: :string, description: 'NOID of the FileSet the asset is listed under — the id tombstone and restore take' },
        mime_type:         { type: :string, nullable: true },
        original_filename: { type: :string, nullable: true },
        size:              { type: :integer, nullable: true },
        filename:          { type: :string, nullable: true },
        label:             { type: :string, nullable: true },
        language:          { type: :string, nullable: true, description: 'BCP 47 language of a caption or other text track; null when unset' },
        track_label:       { type: :string, nullable: true, description: 'Display name a player shows for the track; null when unset' },
        role:              { type: :string, nullable: true, description: 'Stable machine token for the asset role — the Role key (e.g. service_file, small_image, original_file). Match on this, not the human `use` label' },
        classification:    { type: :string, nullable: true,
                             description: 'Classification name of the containing FileSet (Image/PDF/Structured Text/…; "File" = unidentified). Download consumers key on "File" to zip opaque binaries on the fly' },
        gated:             { type:        :boolean,
                             description: 'True if this binary must be authorized rather than downloaded directly: its audience is not public, or the Work is under an active embargo. Blobs classify by media type: image original => original, plus pdf/audio/video; other types ride the Work gate' },
        permission:        { type: :array, items: { type: :string }, nullable: true,
                             description: 'Effective read-group set gating this binary (public / Grouper groups / [] private); null for guests, to whom group names are not disclosed' }
      },
      required:    %w[kind noid],
      description: 'Blob asset — held binary'
    }
  end

  def delegate_asset
    {
      type:        :object,
      properties:  {
        kind:           { type: :string, enum: %w[Delegate],
                          description: 'The asset model. Match on this to tell a Delegate from a Blob: `uri` can be null' },
        noid:           { type: :string },
        file_set:       { type: :string, description: 'NOID of the FileSet the asset is listed under' },
        mime_type:      { type: :string, nullable: true },
        use:            { type: :string, nullable: true, description: 'Human display label for the role (e.g. "Service File"); match on `role` for a stable token' },
        uri:            { type: :string, nullable: true,
                          description: 'The IIIF URL. Null for a gated image role while an embargo withholds it from ' \
                                       'the caller: below staff, without an edit grant on the Work.' },
        label:          { type: :string, nullable: true },
        role:           { type: :string, nullable: true, description: 'Stable machine token for the asset role — the Role key (e.g. service_file, small_image). Match on this, not the human `use` label' },
        classification: { type: :string, nullable: true,
                          description: 'Classification name of the containing FileSet (e.g. Derivative for IIIF tiers)' },
        gated:          { type:        :boolean,
                          description: 'True if this derivative tier must be authorized rather than linked directly: its audience is not public, or the Work is under an active embargo (thumbnails stay open)' },
        permission:     { type: :array, items: { type: :string }, nullable: true,
                      description: 'Effective read-group set gating this tier (public / Grouper groups / [] private); null for guests, to whom group names are not disclosed' }
      },
      required:    %w[kind noid],
      description: 'Delegate asset — external pointer (e.g. IIIF URL)'
    }
  end

  # Polymorphic per-asset item shared by WorkAssets (flattened),
  # WorkFileSets (grouped per page) and TombstonedAssets — mirrors the
  # shared works/_asset.json.jbuilder partial. `stamp` names the tombstoned
  # variants of the branches.
  def asset_item(prefix = '')
    {
      oneOf:         %w[BlobAsset DelegateAsset].map { |name| { '$ref' => "#/components/schemas/#{prefix}#{name}" } },
      discriminator: {
        propertyName: 'kind',
        mapping:      {
          'Blob'     => "#/components/schemas/#{prefix}BlobAsset",
          'Delegate' => "#/components/schemas/#{prefix}DelegateAsset"
        }
      }
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
          tombstoned: { type: :boolean, description: 'Tombstoned (suppressed from discovery) flag' },
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
      depositor:   { type: :string, nullable: true, description: 'Curator NUID (owner). Null for a guest.' },
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
      edit_users:  { type: :array, items: { type: :string }, description: 'Empty for a guest' },
      read_groups: { type: :array, items: { type: :string }, description: 'Only `public` for a guest' },
      edit_groups: { type: :array, items: { type: :string }, description: 'Only `public` for a guest' },
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
        pagination: { '$ref' => '#/components/schemas/SearchPagination' }
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
        pagination: { '$ref' => '#/components/schemas/SearchPagination' }
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
        thumbnail: { type: :string, nullable: true, description: 'IIIF URL of the thumbnail tier, or null' },
        creators:  { type: :array, items: { type: :string }, description: 'The creators, as search reports them' },
        year:      { type: :string, nullable: true, description: 'The created date\'s year, as search reports it' },
        embargoed: { type: :boolean, description: 'Whether an embargo withholds the Work\'s files now' }
      },
      required:   %w[id noid klass title thumbnail creators year embargoed]
    }
  end

  # GET /resources/search (mirrors search/index + search/_result). Every
  # field is read off the Solr doc.
  def search_results
    {
      type:       :object,
      properties: {
        results:    { type: :array, items: search_result },
        pagination: { '$ref' => '#/components/schemas/SearchPagination' }
      },
      required:   %w[results pagination]
    }
  end

  def search_result
    {
      type:       :object,
      properties: {
        id:          { type: :string, description: 'NOID' },
        noid:        { type: :string, description: 'NOID (the same value as id)' },
        klass:       { type: :string, enum: SearchQuery::TYPES, description: 'Resource type' },
        title:       { type: :string, nullable: true },
        creators:    { type: :array, items: { type: :string } },
        year:        { type: :string, nullable: true, description: 'Publication year' },
        thumbnail:   { type: :string, nullable: true, description: 'IIIF URL of the thumbnail tier, or null' },
        in_progress: { type: :boolean, description: 'An unfinished deposit' },
        embargoed:   { type: :boolean },
        incomplete:  { type: :boolean }
      },
      required:   %w[id noid klass title creators year thumbnail in_progress embargoed incomplete]
    }
  end

  # GET /resources/:id/solr. The document is Solr's own, passed through, so its
  # fields follow whatever the indexers and the Solr schema produce.
  def index_document
    bare({
           noid:     { type: :string },
           document: { type: :object, additionalProperties: true,
                       description: 'The Solr document exactly as Solr stores it' }
         })
  end

  # GET /resources/:id/search_explanation. Atlas groups Solr's pieces without
  # reshaping them, so `explanation` is Solr's tree, as deep as the query makes it.
  def search_explanation
    boost_map = { type: :object, additionalProperties: { type: :number }, description: 'Field to boost' }
    bare({
           noid:         { type: :string },
           q:            { type: :string },
           matched:      { type: :boolean },
           score:        { type: :number },
           hidden_by:    { type: :array, items: { type: :string, enum: SearchQuery::CATALOG_FILTERS.keys },
                           description: 'Catalog filters that hide the object whatever it matches' },
           parsed_query: { type: :string, description: "Solr's parsedquery_toString" },
           handler:      bare({ qf: boost_map, pf: boost_map,
                                mm: { type: :string, nullable: true }, tie: { type: :number, nullable: true },
                                boost: { type: :string, nullable: true } }),
           explanation:  { type: :object, additionalProperties: true,
                           description: "Solr's structured explainOther tree, unchanged" },
           fields:       { type: :array, items: search_explanation_field }
         })
  end

  def search_explanation_field
    words = { type: :array, items: { type: :string } }
    token = bare({ text: { type: :string }, start: { type: :integer }, end: { type: :integer },
                   position: { type: :integer }, match: { type: :boolean } })
    bare({
           field:        { type: :string },
           stored:       { type: :boolean },
           query_tokens: bare({ typed: words, analysed: words }).merge(nullable: true),
           values:       { type: :array, items: bare({ source: { type: :string }, text: { type: :string },
                                                       tokens: { type: :array, items: token } }) },
           truncated:    { type: :boolean, description: 'A source had more values than were analysed' },
           reason:       { type: :string, nullable: true,
                           description: 'not_in_schema, full_text, not_stored or analysis_failed; null otherwise' },
           highlights:   words.merge(description: 'Full-text passages, for full_text_tesimv only')
         })
  end

  # Every 4xx and 5xx body that has one. `error` is the discriminator a client
  # branches on; docs/error-contract.md owns the codes and when each fires.
  # OpenapiContract checks every 4xx body a request spec receives against this.
  def error
    {
      type:                 :object,
      description:          'The body of every error that has one. Branch on `error`, never on `message`.',
      properties:           {
        error:                    {
          type:        :string,
          description: <<~TEXT.squish
            What went wrong. A code such as `stale_resource` (409), `tombstoned` (410), `invalid_record`
            (422), `read_only_mode` (503) or `backend_unavailable` (503), or the code of a rejected
            write such as `invalid_parent_type` (422). On a 400, 401 or 403 it is a sentence for a person,
            not a code: branch on the status instead.
          TEXT
        },
        code:                     { type:        :string,
                                    description: 'On some 422s, such as `has_children` or `tombstoned_parent`: the code, ' \
                                                 'while `error` carries a sentence.' },
        message:                  { type: :string, description: 'Detail for a person. Never parse it.' },
        resource_id:              { type: :string, nullable: true, description: 'The NOID the request named.' },
        action:                   { type: :string, description: 'On a 403: the verb that was refused.' },
        subject:                  { type: :string, description: 'On a 403: the type of the resource the verb was refused on.' },
        dependency:               { type: :string, enum: %w[database index storage cache],
                                    description: 'On `backend_unavailable`: the dependency Atlas could not reach.' },
        tombstoned_resource_id:   { type: :string, description: 'On `tombstoned`: the NOID of the tombstoned resource, which can be an ancestor of the one requested.' },
        tombstoned_resource_type: { type: :string, description: 'On `tombstoned`: the type of the tombstoned resource.' }
      },
      required:             %w[error],
      additionalProperties: false
    }
  end

  # pagy's metadata block, every key of Pagy::DEFAULT[:metadata]. `vars` is
  # pagy's own state and is documented as such rather than pinned.
  def pagination
    {
      type:        :object,
      description: 'Where this page sits in the list. Follow `next` until it is null.',
      properties:  {
        count:        { type: :integer, description: 'Items in the whole list.' },
        page:         { type: :integer, description: 'This page\'s number, from 1.' },
        items:        { type: :integer, description: 'The page size.' },
        pages:        { type: :integer, description: 'Pages in the whole list.' },
        last:         { type: :integer, description: 'The last page\'s number.' },
        in:           { type: :integer, description: 'Items on this page.' },
        from:         { type: :integer, description: 'The position of this page\'s first item, from 1; 0 on an empty list.' },
        to:           { type: :integer, description: 'The position of this page\'s last item.' },
        prev:         { type: :integer, nullable: true, description: 'The previous page\'s number, or null on the first page.' },
        next:         { type: :integer, nullable: true, description: 'The next page\'s number, or null on the last page.' },
        series:       { type: :array, items: { oneOf: [{ type: :integer }, { type: :string }] },
                        description: 'Pages to show in a pager: a number for another page, this page\'s ' \
                                     'number as a string, and `gap` for elided pages.' },
        scaffold_url: { type: :string, description: 'This request\'s path with `__pagy_page__` in place of the page number.' },
        first_url:    { type: :string, description: 'The path of the first page.' },
        prev_url:     { type: :string, description: 'The path of the previous page. On the first page it ends `page=` with no number.' },
        page_url:     { type: :string, description: 'The path of this page.' },
        next_url:     { type: :string, description: 'The path of the next page. On the last page it ends `page=` with no number.' },
        last_url:     { type: :string, description: 'The path of the last page.' },
        vars:         { type: :object, additionalProperties: true,
                        description: 'The paginator\'s internal settings. Not part of the contract.' }
      },
      required:    %w[count page items pages last in from to prev next series
                      scaffold_url first_url prev_url page_url next_url last_url vars]
    }
  end

  # The block a Solr-backed list builds itself (SearchQuery, WorkDigestQuery)
  # instead of pagy's.
  def search_pagination
    {
      type:        :object,
      description: 'Where this page sits in a search-backed list. Stop when `page` reaches `pages`.',
      properties:  {
        total:    { type: :integer, description: 'Items in the whole list.' },
        page:     { type: :integer, description: 'This page\'s number, from 1.' },
        per_page: { type: :integer, description: 'The page size.' },
        pages:    { type: :integer, description: 'Pages in the whole list; 0 when it is empty.' }
      },
      required:    %w[total page per_page pages]
    }
  end

  # GET /user renders the record's own to_json, so this is every column of
  # `users` less Devise's serialization blacklist.
  def user
    {
      type:        :object,
      description: 'The calling user\'s account. A guest gets the shared guest account, with no NUID.',
      properties:  {
        id:          { type: :integer },
        nuid:        { type: :string, nullable: true, description: 'The NUID; null for the guest.' },
        email:       { type: :string, description: 'The account\'s email, which tells one account of a NUID from another.' },
        name:        { type: :string, nullable: true, description: '`Family, Given`.' },
        role:        { type: :string, enum: %w[admin privileged standard loader system guest anonymous fixity_checker] },
        groups:      { type: :array, nullable: true, items: { type: :string }, description: 'The account\'s Grouper groups.' },
        affiliation: { type: :string, nullable: true, description: 'A label a person reads for this account.' },
        preferred:   { type: :boolean, description: 'Whether this is the default account for its NUID.' },
        jti:         { type: :string, description: 'The token revocation id. Rotating it revokes every token the account holds.' },
        created_at:  { type: :string, format: 'date-time' },
        updated_at:  { type: :string, format: 'date-time' }
      },
      required:    %w[id nuid email name role groups affiliation preferred jti created_at updated_at]
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
  # nuid, name and the Person display_name, never email/role/groups.
  def user_directory_entry
    {
      type:       :object,
      properties: {
        nuid:         { type: :string },
        name:         { type: :string, nullable: true, description: 'The SSO-fed account name' },
        display_name: { type: :string, nullable: true,
                        description: 'The curated Person name for this NUID; null when there is no Person' }
      },
      required:   %w[nuid name display_name]
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
    wrapped(:resource, {
              embargo:        { type: :string, nullable: true, description: 'The embargo release date, or null.' },
              depositor:      { type: :string, nullable: true, description: 'The depositor\'s NUID.' },
              proxy_uploader: { type: :string, nullable: true, description: 'The NUID of whoever deposited for the depositor.' },
              edit_users:     { type: :array, items: { type: :string }, description: 'NUIDs granted edit.' },
              read:           { type: :array, items: { type: :string }, description: 'Groups granted read; `public` for everyone.' },
              edit:           { type: :array, items: { type: :string }, description: 'Groups granted edit.' },
              type:           { type: :string, description: 'The resource\'s type.' }
            }, description: 'The resource\'s access-control envelope. For a guest, depositor and proxy_uploader ' \
                            'are null, edit_users is empty, and read and edit keep only `public`.')
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
          tombstoned: { type: :boolean, description: 'Tombstoned (suppressed from discovery) flag — kept in the result but flagged' }
        },
        required:   %w[id noid klass title thumbnail tombstoned]
      }
    }
  end

  # ---- helpers ----

  def tombstone_reason_prop
    { '$ref' => '#/components/schemas/TombstoneReason' }
  end

  # One component rather than an inline enum on every record, so a generated
  # client gets one type for it.
  def tombstone_reason
    { type: :string, nullable: true, enum: [*Resource::TOMBSTONE_REASONS, nil],
      description: 'The policy removal note chosen at tombstoning, or null. The date comes from tombstoned_at.' }
  end

  def base_resource_props
    {
      id:               { type: :string, description: 'NOID' },
      valkyrie_id:      { type: :string, description: 'Valkyrie internal id' },
      ancestors:        ancestor_nodes,
      thumbnail:        { type: :string, nullable: true, description: 'IIIF URL of the :thumbnail_image Delegate (~85px), or null' },
      thumbnail_2x:     { type: :string, nullable: true, description: 'IIIF URL of the :thumbnail_image_2x Delegate (~170px retina), or null' },
      preview:          { type: :string, nullable: true, description: 'IIIF URL of the :preview_image Delegate (~500px hero), or null' },
      **preview_facts_props,
      title:            { type: :string, nullable: true },
      description:      { type: :string, nullable: true },
      permanent_url:    { type: :string, nullable: true },
      tombstoned:       { type: :boolean, description: 'Tombstoned (suppressed from discovery) flag' },
      tombstoned_at:    { type: :string, nullable: true, description: 'ISO-8601 timestamp set when tombstoned' },
      tombstoned_by:    { type: :string, nullable: true, description: 'NUID of the user who tombstoned the resource' },
      tombstone_reason: tombstone_reason_prop,
      updated_at:       updated_at_prop
    }.merge(provenance_props)
  end

  # What the preview Delegate says about its image, beside its URI.
  def preview_facts_props
    {
      preview_width:       { type: :integer, nullable: true, description: 'Pixel width of the image `preview` serves, or null' },
      preview_height:      { type: :integer, nullable: true, description: 'Pixel height of the image `preview` serves, or null' },
      preview_placeholder: { type: :string, nullable: true, format: :byte,
                             description: 'Base64 of a ~16px-wide JPEG of the preview image, for a blurred stand-in, or null' }
    }
  end

  # Resource-level provenance fields surfaced by Work / Collection /
  # Community show responses. Pulled out so base_resource_props stays
  # within the MethodLength budget; mirrors how `work_only_props` is
  # split out for Work-specific keys.
  def provenance_props
    {
      depositor:      { type: :string, nullable: true, description: 'NUID of the intellectual owner (the named depositor; may differ from the hands-on-keyboard actor). Null for a guest.' },
      proxy_uploader: { type: :string, nullable: true, description: 'NUID of the hands-on-keyboard actor for the most-recent create. Equals depositor for self-deposit; differs in the librarian-on-behalf (proxy-deposit) case. Left null under acting-as impersonation (On-Behalf-Of header present) — the operator is recorded only in the AuditEvent, not on the resource. Null for a guest.' }
    }
  end

  # ancestors is the chain root-first, each node an object carrying the
  # ancestor's title under named keys — so breadcrumb consumers get the title
  # without a per-ancestor round-trip.
  def ancestor_nodes
    {
      type:        :array,
      description: 'Ancestor chain, root-first, with titles and structural flags — array of {noid, klass, title, system_container, personal_root} objects',
      items:       {
        type:       :object,
        properties: {
          noid:             { type: :string, description: 'Ancestor NOID' },
          klass:            { type: :string, description: 'Ancestor resource class name' },
          title:            { type: :string, description: 'Ancestor plain-text title (may be empty)' },
          system_container: { type: :boolean, description: 'True for the People system Community. Always false for a non-Community.' },
          personal_root:    { type: :boolean, description: "True for a Person's personal-root Collection. Always false for a non-Collection." }
        },
        required:   %w[noid klass title system_container personal_root]
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

  # GET /{resource}/{id}/mods with Accept: application/json — the JSON access
  # copy of a resource's descriptive metadata. The preservation copy is the
  # MODS XML; this is the fast read over it.
  #
  # Derived from the gem's field registry rather than restated, for the same
  # reason Metadata::MODS derives its attr_json set: a second hand-kept list of
  # the field names is what let fields drift out of a reader's sight. A new
  # field in neu-mods appears here with no edit, and the response body and this
  # schema cannot disagree about which fields exist.
  def work_mods
    {
      type:       :object,
      properties: {
        work: {
          type:       :object,
          properties: {
            id:   { type: :string, description: 'NOID of the work' },
            mods: mods_document
          }
        }
      },
      required:   %w[work]
    }
  end

  # GET /works/{id}/citation: CSL-JSON, with an absent fact left out rather than
  # null, so only id, type and title are required. Mirrors works/citation.json.jbuilder.
  def citation
    csl_name = { type: :object, properties: { literal: { type: :string } }, required: %w[literal],
                 additionalProperties: false }
    {
      type:                 :object,
      description:          'The Work as a CSL-JSON item (Citation Style Language), ready for a reference manager or ' \
                            'a CSL formatter. Names are literal: the record does not say which are personal.',
      properties:           {
        id:          { type: :string, description: 'The Work\'s NOID.' },
        type:        { type: :string, enum: [*Citation::GENRE_TYPES.values, *Citation::RESOURCE_TYPES.values,
                                             Citation::DEFAULT_TYPE].uniq.sort,
                       description: 'The CSL item type, from the genre, then the type of resource.' },
        title:       { type: :string },
        author:      { type: :array, items: csl_name, description: 'The creators, in record order.' },
        contributor: { type: :array, items: csl_name, description: 'The other named contributors.' },
        issued:      {
          description: 'The created date, to the precision the record states, or its own words when it ' \
                       'gives a date it could not encode.',
          oneOf:       [
            { type: :object, required: %w[date-parts], additionalProperties: false,
              properties: { 'date-parts': { type: :array, items: { type: :array, items: { type: :integer } } } } },
            { type: :object, required: %w[literal], additionalProperties: false,
              properties: { literal: { type: :string } } }
          ]
        },
        abstract:    { type: :string },
        keyword:     { type: :string, description: 'The topical subjects, comma-separated.' },
        URL:         { type: :string, description: 'The Work\'s persistent URL, its handle.' }
      },
      required:             %w[id type title],
      additionalProperties: false
    }
  end

  # The JSON access copy of a container's MODS: the same projection as a
  # Work's, under the container's own key.
  def container_mods(key)
    {
      type:       :object,
      properties: {
        key => {
          type:       :object,
          properties: {
            id:   { type: :string, description: "NOID of the #{key}" },
            mods: mods_document
          }
        }
      },
      required:   [key.to_s]
    }
  end

  # GET /resources/{id}/mods renders the typed route's body for whatever the
  # NOID resolves to.
  def resource_mods
    { oneOf: %w[WorkMods CollectionMods CommunityMods].map { |name| { '$ref' => "#/components/schemas/#{name}" } } }
  end

  # The JSON projection of a structural (METS) record. `pages` is the Work's
  # physical page order, and empty on a FileSet's record.
  def mets(key)
    wrapped(key, {
              id:   { type: :string, description: "NOID of the #{key.to_s.tr('_', ' ')}" },
              mets: bare({
                           agent:           { type: :string, nullable: true, description: 'The agent that wrote the METS.' },
                           created_at_iso:  { type: :string, nullable: true, description: 'When the METS was written.' },
                           structure_label: { type: :string, nullable: true },
                           files:           { type: :array, items: mets_file_entry },
                           pages:           { type: :array, items: mets_page_entry }
                         })
            })
  end

  def mets_file_entry
    {
      type:       :object,
      properties: {
        id:        { type: :string, nullable: true },
        mime_type: { type: :string, nullable: true },
        use:       { type: :string, nullable: true }
      }
    }
  end

  def mets_page_entry
    {
      type:       :object,
      properties: {
        noid:  { type: :string, description: 'NOID of the page\'s FileSet' },
        order: { type: :integer, nullable: true, description: '1-based page order; absent or null when the page has no position' },
        label: { type: :string, nullable: true }
      },
      required:   %w[noid]
    }
  end

  # GET /works/{id}/dwc as JSON. The term list is open, so the record is a map
  # of term name to value rather than a fixed property set.
  def work_darwin_core
    wrapped(:work, {
              id:  { type: :string, description: 'NOID of the work' },
              dwc: {
                type:                 :object,
                additionalProperties: { type: :string },
                description:          'Each dwc:, dc: and dcterms: term of the single dwr:SimpleDarwinRecord, ' \
                                      'keyed by its term name (catalogNumber, scientificName, ...). Blank ' \
                                      'terms and terms in other namespaces are left out.'
              }
            })
  end

  def mods_document
    {
      type:       :object,
      properties: NEU::MODS::FIELDS.to_h { |field, cardinality| [field, mods_property(field, cardinality)] }
    }
  end

  # The two members every DISPLAYED field carries: the header the record asked
  # for (@displayLabel) and the link it attached (xlink:href). Spelled once and
  # merged in below, the way the projection reads them as one pair.
  MODS_DISPLAY_MEMBERS = %i[display_label href].freeze

  # The three members every BROWSABLE field carries beside those: the
  # vocabulary its value was taken from, which is what a consumer gates a
  # browse link on. Only the fields below have them -- nothing gates on the
  # vocabulary of an extent, and three more members on every displayed field
  # is a schema no consumer reads.
  MODS_AUTHORITY_MEMBERS = %i[authority authority_uri value_uri].freeze

  MODS_BROWSABLE_FIELDS =
    (%i[names origin_agents languages subject_headings] + Metadata::MODS::AUTHORIZED_VALUE_FIELDS).freeze

  # The three object fields that carry NEITHER: MODS puts no @displayLabel on
  # hierarchicalGeographic, recordInfo takes one but describes the cataloguing
  # rather than the resource, and a primary title's label is a scalar companion
  # because the title itself is a parts model.
  MODS_UNLABELED_OBJECT_PROPS = {
    main_title:                       %i[title subtitle part_number part_name non_sort],
    record_info:                      %i[content_source origin description_standard creation_date
                                         change_date language_of_cataloging],
    hierarchical_geographic_subjects: %i[continent country province region state territory
                                         county city city_section island area]
  }.freeze

  # MODS fields whose members are objects rather than strings; everything else
  # is a string, singular or an array according to its registry cardinality.
  MODS_OBJECT_PROPS = {
    names:                %i[name roles affiliation usage alternative_names],
    languages:            %i[term object_part script],
    notes:                %i[type value],
    host_collections:     %i[title volume issue start_page end_page date text
                             details extents],
    # :heading is the parts joined, which is the string the display renders AND
    # the string the browse index holds; :axis names the MODS element the
    # heading's main term came from, which is the facet it browses in.
    subject_headings:     %i[parts heading axis],
    location:             %i[physical_location shelf_location url],
    map_data:             %i[scale projection coordinates],
    related_items:        %i[type title],
    identifiers:          %i[type value invalid],
    place_of_publication: %i[value event_type date_elements],
    origin_agents:        %i[name roles affiliation usage alternative_names event_type]
  }.merge(Metadata::MODS::LABELED_VALUE_FIELDS.index_with { %i[value] })
                      .merge(Metadata::MODS::AUTHORIZED_VALUE_FIELDS.index_with { %i[value] })
                      .merge(Metadata::MODS::ORIGIN_VALUE_FIELDS.index_with { %i[value event_type] })
                      .transform_values { |members| members + MODS_DISPLAY_MEMBERS }
                      .merge(MODS_UNLABELED_OBJECT_PROPS)
                      .to_h do |field, members|
                        browsable = MODS_BROWSABLE_FIELDS.include?(field)
                        [field, browsable ? members + MODS_AUTHORITY_MEMBERS : members]
                      end
                      .freeze

  # The originInfo dates serialise as timestamps, both ends of a range alike.
  # Their precision and qualifier siblings are plain strings. All seven MODS
  # dates are here, including the four that render nowhere -- the response body
  # carries them whether or not a page does.
  MODS_DATE_PROPS = %i[date_created date_created_end
                       date_issued date_issued_end
                       copyright_date copyright_date_end
                       date_captured date_captured_end
                       date_valid date_valid_end
                       date_other date_other_end
                       date_modified date_modified_end].freeze

  # keyDate="yes" is the record nominating its own principal date, so it
  # crosses the wire as a boolean rather than as the string "yes".
  MODS_BOOLEAN_PROPS = %i[date_created_key_date date_issued_key_date
                          copyright_date_key_date date_captured_key_date
                          date_valid_key_date date_other_key_date
                          date_modified_key_date].freeze

  def mods_property(field, cardinality)
    member = mods_member(field)
    cardinality == :many ? { type: :array, items: member } : member.merge(nullable: true)
  end

  def mods_member(field)
    if MODS_OBJECT_PROPS.key?(field)
      # The member keys are documented in MODS_OBJECT_PROPS but not enumerated
      # here: attr_json stores only the keys a value actually set, so a name
      # with no role serialises without the key at all, and strict validation
      # would demand every part of every member. The field set above is the
      # contract that matters -- it is the one that drifts.
      { type: :object }
    elsif MODS_DATE_PROPS.include?(field)
      { type: :string, format: 'date-time' }
    elsif MODS_BOOLEAN_PROPS.include?(field)
      { type: :boolean }
    else
      { type: :string }
    end
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
              original_filename: { type: :string, nullable: true, description: "This revision's filename. A replace can rename the file, so revisions can differ" }
            },
            required:   %w[revision version_id file_identifier created actor_nuid on_behalf_of_nuid digest size original_filename]
          }
        }
      },
      required:   %w[blob_id versions]
    }
  end

  # GET /works/:id/file_revisions — the general-audience sibling of
  # BlobVersions: one entry per replaced Blob on the Work, each revision
  # reduced to its ordinal and date. Strict validation keeps the attribution
  # fields from creeping in under the Work's read gate.
  def work_file_revisions
    {
      type:  :array,
      items: {
        type:       :object,
        properties: {
          blob_id:   { type: :string, description: 'NOID of the Blob' },
          revisions: {
            type:  :array,
            items: {
              type:       :object,
              properties: {
                revision: { type: :integer, description: 'Contiguous 1-based content-revision ordinal; revision 1 is the seed' },
                created:  { type: :string, format: 'date-time', description: 'OCFL version creation timestamp (ISO-8601)' }
              },
              required:   %w[revision created]
            }
          }
        },
        required:   %w[blob_id revisions]
      }
    }
  end

  # POST /files/find_many_versions — the batched read. One BlobVersions envelope
  # per resolved Blob, reusing that shape unchanged so the descriptor contract
  # can't fork between the single and batch reads. Possibly shorter than the
  # requested id list; callers index by blob_id.
  def blob_versions_batch
    {
      type:  :array,
      items: { '$ref' => '#/components/schemas/BlobVersions' }
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
        file_set:            { type: :string, nullable: true, description: 'NOID of the parent FileSet; null when unresolvable' },
        work:                { type: :string, nullable: true, description: 'NOID of the containing Work; null when unresolvable' },
        file_set_tombstoned: { type: :boolean, nullable: true, description: 'Whether the FileSet is tombstoned; null with file_set' },
        work_tombstoned:     { type: :boolean, nullable: true, description: 'Whether the Work is tombstoned; null with work' }
      },
      required:   %w[file_set work file_set_tombstoned work_tombstoned]
    }
  end

  # The 410 a tombstone answers on a file or a file list. The tombstoned
  # resource can be an ancestor of the one requested, so the body names it.
  def tombstoned_error
    {
      type:       :object,
      properties: {
        error:                    { type: :string, enum: ['tombstoned'] },
        resource_id:              { type: :string, description: 'NOID that was requested' },
        tombstoned_resource_id:   { type: :string, description: 'NOID of the resource whose tombstone applies' },
        tombstoned_resource_type: { type:        :string,
                                    description: 'Its type: Community, Collection, Work, FileSet, Blob or Delegate' },
        message:                  { type: :string }
      },
      required:   %w[error resource_id tombstoned_resource_id tombstoned_resource_type message]
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
