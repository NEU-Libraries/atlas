# frozen_string_literal: true

module OpenapiSchemas
  module_function

  # Each schema mirrors a jbuilder partial in app/views/. When a partial
  # changes, the corresponding entry here must change too — strict schema
  # validation in rswag will otherwise fail the request specs.

  def all
    {
      Work:        work,
      Collection:  collection,
      Community:   community,
      FileSet:     file_set,
      Blob:        blob,
      WorkSummary: work_summary,
      CollectionSummary: collection_summary,
      CommunitySummary: community_summary,
      FileSetSummary: file_set_summary,
      BlobSummary: blob_summary,
      WorksIndex:  works_index,
      CollectionsIndex: collections_index,
      CommunitiesIndex: communities_index,
      FileSetsIndex: file_sets_index,
      BlobsIndex:  blobs_index,
      WorkBlobs:   work_blobs,
      Pagination:  pagination,
      User:        user,
      Permissions: permissions,
      ResourceRef: resource_ref,
      Lineage:     lineage
    }
  end

  # ---- detail shapes (one wrapped object) ----

  def work
    wrapped(:work, base_resource_props)
  end

  def collection
    wrapped(:collection, base_resource_props)
  end

  def community
    wrapped(:community, base_resource_props)
  end

  def file_set
    wrapped(:file_set, {
      id: { type: :string, description: 'NOID' },
      type: { type: :string, nullable: true }
    })
  end

  def blob
    wrapped(:blob, {
      id: { type: :string, description: 'NOID' },
      mime_type: { type: :string, nullable: true },
      original_filename: { type: :string, nullable: true },
      use: { type: :string, nullable: true },
      size: { type: :integer, nullable: true },
      filename: { type: :string, nullable: true },
      label: { type: :string, nullable: true },
      file_identifiers: {
        type: :array,
        items: { type: :object, additionalProperties: true,
                 description: 'Valkyrie::ID-shaped reference to the underlying bytes' }
      }
    })
  end

  # ---- summary shapes (used by index actions) ----

  def work_summary
    wrapped(:work, summary_props)
  end

  def collection_summary
    wrapped(:collection, summary_props)
  end

  def community_summary
    wrapped(:community, summary_props)
  end

  def file_set_summary
    wrapped(:file_set, {
      id: { type: :string, description: 'NOID' },
      type: { type: :string, nullable: true }
    })
  end

  def blob_summary
    wrapped(:blob, { id: { type: :string } })
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

  def file_sets_index
    paged(:file_sets, { '$ref' => '#/components/schemas/FileSetSummary' })
  end

  def blobs_index
    paged(:blobs, { '$ref' => '#/components/schemas/BlobSummary' })
  end

  # ---- specialized shapes ----

  # GET /works/:id/files — flat array of file refs from FileSets attached to a Work.
  # Mirrors app/views/works/blobs.json.jbuilder.
  def work_blobs
    {
      type: :array,
      items: {
        type: :object,
        properties: {
          noid: { type: :string },
          mime_type: { type: :string, nullable: true },
          original_filename: { type: :string, nullable: true },
          size: { type: :integer, nullable: true },
          label: { type: :string, nullable: true }
        },
        required: %w[noid]
      }
    }
  end

  def pagination
    {
      type: :object,
      description: 'pagy pagination block',
      additionalProperties: true
    }
  end

  # GET /user uses `render :json => current_user.to_json` so the response is
  # the AR record's default JSON serialization (id, email, name, role, …),
  # *not* the jbuilder envelope. Permissive schema documents the shape
  # without pinning every Devise/AR field.
  def user
    {
      type: :object,
      description: 'Devise/AR User record serialized via to_json. Fields vary; commonly includes id, email, name, role.',
      properties: {
        id: { type: :integer },
        email: { type: :string, nullable: true },
        name: { type: :string, nullable: true },
        role: { type: :string, nullable: true }
      },
      additionalProperties: true
    }
  end

  def permissions
    wrapped(:resource, {}, additional: true,
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
        { '$ref' => '#/components/schemas/FileSet' }
      ]
    }
  end

  # ---- helpers ----

  def base_resource_props
    {
      id: { type: :string, description: 'NOID' },
      valkyrie_id: { type: :string, description: 'Valkyrie internal id' },
      ancestors: ancestor_pairs,
      thumbnail: { type: :string, nullable: true },
      title: { type: :string, nullable: true },
      description: { type: :string, nullable: true }
    }
  end

  # ancestors comes back as an array of [noid, type-name] 2-tuples,
  # e.g. [["c-123", "Community"], ["col-456", "Collection"]]
  def ancestor_pairs
    {
      type: :array,
      items: {
        type: :array,
        items: { type: :string },
        minItems: 2,
        maxItems: 2,
        description: '[noid, type-name] pair'
      }
    }
  end

  def lineage
    ancestor_pairs.merge(description: 'Ancestor or descendant chain — array of [noid, type-name] pairs')
  end

  def summary_props
    {
      id: { type: :string },
      title: { type: :string, nullable: true },
      description: { type: :string, nullable: true }
    }
  end

  # Wrap a property block under a single key (matches jbuilder `json.work do ... end`).
  def wrapped(key, properties, additional: false, description: nil)
    inner = { type: :object, properties: properties, required: properties.keys.map(&:to_s) }
    inner[:additionalProperties] = true if additional
    inner[:description] = description if description
    {
      type: :object,
      properties: { key => inner },
      required: [key.to_s]
    }
  end

  # Paged collection: wrap an array under a key alongside the pagination block.
  def paged(key, item_schema)
    {
      type: :object,
      properties: {
        key => { type: :array, items: item_schema },
        pagination: { '$ref' => '#/components/schemas/Pagination' }
      },
      required: [key.to_s, 'pagination']
    }
  end
end
