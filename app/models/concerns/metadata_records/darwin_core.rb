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

    # A draft's access copy, never saved, for POST /resources/preview. The
    # parse raises the same 422s a PUT would.
    def preview_darwin_core(raw_xml)
      @darwin_core = Metadata::DarwinCore.new(valkyrie_id:     noid,
                                              json_attributes: DarwinCoreDocument.parse(raw_xml).to_h)
      self
    end

    # The bytes as stored, not reformatted: this is the download Cerberus hands
    # out as a standalone file.
    def darwin_core_xml
      return nil unless darwin_core?

      darwin_core_blob&.file&.read
    end

    # Checks the document before writing anything, so a refused upload leaves
    # no OCFL version behind. A PUT onto a tombstoned record restores it.
    #
    # The whole write holds the first build's lock, for the reason Modsable#mods_xml= does.
    def darwin_core_xml=(raw_xml)
      terms = DarwinCoreDocument.parse(raw_xml).to_h
      AdvisoryLock.hold('darwin_core', id) do
        blob = darwin_core_blob || create_darwin_core_blob
        stored = with_tmp_file(raw_xml, '-dwc.xml') { |path| create_file(path, blob, FILENAME) }
        blob.file_identifiers += [stored.version_id]
        Atlas.persister.save(resource: blob)
        restore_darwin_core_file_set

        record = Metadata::DarwinCore.find_or_create_by(valkyrie_id: noid)
        record.update!(json_attributes: terms)
        @darwin_core = record
        reindex_darwin_core
      end
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

      AdvisoryLock.hold('darwin_core', id) do
        if (file_set = darwin_core_file_set)
          file_set.tombstone(by: by)
          Atlas.persister.save(resource: file_set).write_preservation_envelope!
        end
        Metadata::DarwinCore.find_by(valkyrie_id: noid)&.destroy!
        @darwin_core = nil
        reindex_darwin_core
      end
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

      # Mirrors Work#create_mets_blob: lazy, locked, and checked again under the lock.
      def create_darwin_core_blob
        AdvisoryLock.hold('darwin_core', id) do
          self.class.find(id).darwin_core_blob || build_darwin_core_blob
        end
      end

      def build_darwin_core_blob
        fs = darwin_core_file_set ||
             FileSetCreator.call(work_id: id, classification: Classification.darwin_core)
        blob = Atlas.persister.save(resource: Blob.new(use: Role.darwin_core.name, mime_type: 'application/xml',
                                                       original_filename: FILENAME))
        fs = StaleRetry.run("attach Darwin Core Blob to #{fs.noid}") do |attempt|
          fs = FileSet.find(fs.id) if attempt.positive?
          fs.member_ids += [blob.id]
          Atlas.persister.save(resource: fs)
        end
        blob.write_preservation_envelope!
        fs.write_preservation_envelope!
        blob
      end

      # The new version is listed on the Blob by now, so losing to a concurrent
      # DELETE or PUT here would answer an error for an upload that landed.
      def restore_darwin_core_file_set
        saved = StaleRetry.run("restore Darwin Core FileSet of #{noid}") do |attempt|
          file_set = attempt.positive? ? FileSet.find(darwin_core_file_set.id) : darwin_core_file_set
          next nil unless file_set&.tombstoned

          file_set.restore
          Atlas.persister.save(resource: file_set)
        end
        saved&.write_preservation_envelope!
      end
  end
end
