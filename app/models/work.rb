# frozen_string_literal: true

class Work < Resource
  include Metsable
  include TierVisibility

  # The typed, directed edges between two separate Works (v1's "associated
  # works"): a codebook, a figure, a transcription and so on, each pointing
  # at the Work it belongs to. The subordinate Work stores the edge; the
  # other end is read back with find_inverse_references_by, so the reverse
  # edge is never stored and can never drift out of step with the forward
  # one.
  #
  # Five named attributes rather than one encoded string, because
  # find_inverse_references_by needs a real property to query — it cannot
  # read a type out of "codebook_for:abc123" — and because these are v1's
  # own predicate names, so a migration maps one to one. The cost is that a
  # sixth relationship type needs an Atlas release; the vocabulary has not
  # changed since v1.
  ASSOCIATION_TYPES = %i[is_codebook_for is_figure_for is_instructional_material_for
                         is_supplemental_material_for is_transcription_of].freeze

  ASSOCIATION_TYPES.each do |predicate|
    attribute predicate, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  end

  # The one structural home (Tree). Scalar — a Work lives in exactly one
  # Collection. Mirrors FileSet's existing scalar a_member_of.
  attribute :a_member_of, Valkyrie::Types::ID
  # The many discovery links (DAG overlay). A Work can be a "linked member"
  # of additional Collections without duplicating the object. Leaves-only:
  # only Works carry this; the collection/community backbone stays a strict
  # tree, so cycles are structurally impossible. Adds placement, never
  # permission — the Work keeps its single ACL.
  attribute :a_linked_member_of, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  attribute :type, Valkyrie::Types::String.default(Classification.work.name.freeze)

  # Operator-visibility flag: Cerberus's bulk-deposit jobs leave this true
  # until they've confirmed all expected children are deposited, then flip
  # it to false via POST /works/:id/complete. Indexed in Solr so the
  # /works?in_progress=true monitoring query can find stuck deposits.
  attribute :in_progress, Valkyrie::Types::Bool.default(true)

  # Sibling of in_progress for the other half of the lifecycle: the deposit
  # finished, but a work-scoped enrichment job (PDF rendition, derivatives,
  # full text) gave up after its retries. It FLAGS and never hides — a record
  # with its file, title and metadata but one missing derivative is degraded,
  # not broken, so it stays readable. Cerberus sets it from a give-up handler
  # and clears it when a later run of the same job succeeds, which makes the
  # state self-healing. Indexed in Solr so a result row can carry an
  # "Incomplete" pill without a per-row fetch.
  attribute :incomplete, Valkyrie::Types::Bool.default(false)

  # Why the pipeline gave up, as a machine token (pdf_rendition_gave_up,
  # media_rendition_gave_up, ingest_gave_up, …), so the caller can phrase the
  # message and group a staff list by cause. Atlas holds it as an opaque
  # string and deliberately does not validate it: the vocabulary belongs to
  # Cerberus, the only writer, so a token added in a Cerberus job must not
  # need an Atlas release to be accepted.
  attribute :incomplete_reason, Valkyrie::Types::String.optional

  # The persistent identifier minted at /complete: "<prefix>/<noid>" (see
  # HandleMinter). Unlike the derived fields below, this one IS
  # preservation-relevant — an external Handle service registers it and
  # off-site citations point at it, so nothing in the repository can
  # re-derive the binding between object and identifier. It therefore rides
  # the OCFL envelope (schema v5), not Postgres and Solr alone. Nil until a
  # Work is finalized, and on every Work where no handle server is configured.
  attribute :handle, Valkyrie::Types::String.optional

  # Derived full-document text, extracted by Cerberus (pdftotext / Tika in a
  # Solid Queue job) and PATCHed in via /works/:id/full_text — the Work-level
  # aggregate of its content FileSets' body text. A regenerable **search aid**,
  # NOT a preservation artifact: it's re-sent on any re-ingest, so it is
  # deliberately omitted from the OCFL preservation envelope (graph_payload),
  # exactly like the fungible thumbnail derivatives ([[project_thumbnail_fungible]]).
  # Stored in the Postgres source of truth (the metadata adapter's jsonb) so
  # FullTextIndexer re-reads it and re-projects full_text_tesimv on every reindex /
  # reset:data. Size is unbounded-ish (a long PDF is MBs of text).
  attribute :full_text, Valkyrie::Types::String

  # Per-tier read-visibility policy for the Work's sized image derivatives —
  # a JSON-encoded sparse map of tier => [read groups], e.g.
  # {"large":["northeastern:drs:...:archives"]}. Read/written through the
  # TierVisibility concern, never raw. Stored as a JSON string rather than a
  # Valkyrie::Types::Hash because the metadata adapter collapses single-element
  # array values ({"small"=>["public"]} round-trips as {"small"=>"public"}),
  # which would corrupt the group-set arrays. Derived/advisory (Cerberus + the
  # IIIF layer enforce it), so it lives in Postgres/Solr, not the OCFL envelope,
  # like [[project_thumbnail_fungible]].
  attribute :derivative_permissions, Valkyrie::Types::String

  # Page-bearing FileSets in presentation order: position ASC, unordered
  # (nil) last, creation-order tie-break — a total order even over
  # legacy/unordered data. Shared by works#file_sets and the Work-level
  # METS structMap so the runtime read and the preservation record can't
  # disagree.
  def page_file_sets
    children
      .select { |c| c.is_a?(FileSet) && c.page? }
      .sort_by { |fs| [fs.position.nil? ? 1 : 0, fs.position || 0, fs.created_at] }
  end

  # Work-level METS lives in a sibling :structural_metadata FileSet (the
  # MODS/descriptive-metadata shape) — a Work has no member_ids, and its
  # children stay exclusively FileSets. Overrides Metsable's flat
  # member_ids storage, which fits FileSet but not Work.
  def mets_blob
    structural_metadata_file_set&.files&.compact&.find { |b| b.use == Role.structural_metadata.name }
  end

  private

    def structural_metadata_file_set
      children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }
    end

    # Created lazily at first METS write (i.e. at /complete) — existing
    # Works need no backfill, and never-completed Works never grow one.
    # Mirrors Modsable#create_mods_blob's sibling-FileSet shape.
    def create_mets_blob
      fs = structural_metadata_file_set ||
           FileSetCreator.call(work_id: id, classification: Classification.structural_metadata)
      blob = Atlas.persister.save(resource: Blob.new(use: Role.structural_metadata.name))
      fs.member_ids += [blob.id]
      Atlas.persister.save(resource: fs)
      blob.write_preservation_envelope!
      fs.write_preservation_envelope!
      blob
    end
end
