# frozen_string_literal: true

module MetadataRecords
  # A Work's Darwin Core record: one Simple Darwin Core document, preserved as
  # dwc.xml in a Blob on a sibling :darwin_core FileSet, with a JSON access copy
  # in metadata_darwin_core. See docs/metadata-records.md.
  #
  # Unlike MODS, a Work need not hold one. The FileSet is created on the first
  # write, and a DELETE tombstones it, so the bytes and their history stay.
  module DarwinCore
    extend ActiveSupport::Concern
    include FileHelper

    SOURCE   = 'dwc'
    FILENAME = 'dwc.xml'

    # The access copy, and the one thing the read path consults: a tombstone
    # deletes the row, so its presence is what "the Work holds a record" means.
    def darwin_core
      return @darwin_core if defined?(@darwin_core)

      @darwin_core = Metadata::DarwinCore.find_by(valkyrie_id: noid)
    end

    def darwin_core?
      darwin_core.present?
    end

    # The bytes as stored, not reformatted: this is the download Cerberus hands
    # out as a standalone file.
    def darwin_core_xml
      return nil unless darwin_core?

      darwin_core_blob&.file&.read
    end

    # Checks the document before writing anything, so a refused upload leaves
    # no OCFL version behind. A PUT onto a tombstoned record restores it.
    def darwin_core_xml=(raw_xml)
      terms = DarwinCoreDocument.parse(raw_xml).to_h
      blob  = darwin_core_blob || create_darwin_core_blob
      stored = with_tmp_file(raw_xml, '-dwc.xml') { |path| create_file(path, blob, FILENAME) }
      blob.file_identifiers += [stored.version_id]
      Atlas.persister.save(resource: blob)
      restore_darwin_core_file_set

      record = Metadata::DarwinCore.find_or_create_by(valkyrie_id: noid)
      record.update!(json_attributes: terms)
      @darwin_core = record
      reindex_darwin_core
    end

    def darwin_core_blob
      file_set = darwin_core_file_set
      return nil if file_set.nil?

      file_set.files.compact.find { |b| b.use == Role.darwin_core.name }
    end

    # The JSON row goes and the FileSet is tombstoned; the OCFL object stays.
    # A rebuild from disk reads the tombstone off the envelope and skips the
    # record, so the two sides agree. A no-op when there is nothing to tombstone.
    def tombstone_darwin_core!(by:)
      return unless darwin_core?

      if (file_set = darwin_core_file_set)
        file_set.tombstone(by: by)
        Atlas.persister.save(resource: file_set).write_preservation_envelope!
      end
      darwin_core.destroy!
      @darwin_core = nil
      reindex_darwin_core
    end

    # Chained through super so each format adds its own token.
    def metadata_formats
      formats = defined?(super) ? super : []
      darwin_core? ? formats + [SOURCE] : formats
    end

    private

      # A record write saves no Work, so nothing else re-projects its Solr doc.
      # Solr only, as FileSetCreator does: the index adapter never bumps the
      # optimistic-lock token, so this cannot 409 a concurrent edit of the Work.
      def reindex_darwin_core
        ResponseCache.evict(noid)
        Atlas.reindex(self)
      end

      def darwin_core_file_set
        children.find { |c| c.is_a?(FileSet) && c.type == Classification.darwin_core.name }
      end

      # Mirrors Work#create_mets_blob: lazy, so existing Works need no backfill.
      def create_darwin_core_blob
        fs = darwin_core_file_set ||
             FileSetCreator.call(work_id: id, classification: Classification.darwin_core)
        blob = Atlas.persister.save(resource: Blob.new(use: Role.darwin_core.name, mime_type: 'application/xml',
                                                       original_filename: FILENAME))
        fs.member_ids += [blob.id]
        Atlas.persister.save(resource: fs)
        blob.write_preservation_envelope!
        fs.write_preservation_envelope!
        blob
      end

      def restore_darwin_core_file_set
        file_set = darwin_core_file_set
        return unless file_set&.tombstoned

        file_set.restore
        Atlas.persister.save(resource: file_set).write_preservation_envelope!
      end
  end
end
