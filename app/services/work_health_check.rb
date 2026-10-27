# frozen_string_literal: true

require_relative '../../lib/ocfl_health'

# Grades one Work green, yellow or red: green is viable, yellow is repairable
# from what Postgres or disk still holds, red has lost bytes and needs a
# restore or a re-deposit. docs/work-health.md has the rubric and the
# destructive probe each rule comes from.
class WorkHealthCheck < ApplicationService
  Finding = OcflHealth::Finding

  def initialize(noid:, fixity: false)
    @noid = noid
    @fixity = fixity
    @findings = []
  end

  def call
    @work = Work.find(@noid)
    if @work.nil?
      add(:fatal, :work_missing, 'no Work with this NOID in Postgres')
    else
      check_metadata
      check_placement
      check_permissions
      check_content
      check_lifecycle
      check_index
      check_disk
    end
    { noid: @noid, grade: OcflHealth.grade(@findings), findings: @findings.map(&:to_h),
      fixity: @work && FixityResult.summary(@work.preserved_resources.map(&:noid)) }
  end

  private

    def add(severity, code, message, subject = @noid)
      @findings << Finding.new(severity: severity, code: code, message: message, subject: subject)
    end

    def file_sets
      @file_sets ||= @work.children.grep(FileSet)
    end

    def descriptive_file_set
      file_sets.find { |fs| fs.type == Classification.descriptive_metadata.name }
    end

    # The access copy serves every read, so its absence is what a reader sees;
    # the XML is what a rebuild needs, so its absence is the loss.
    def check_metadata
      if @work.mods.nil?
        add(:repairable, :mods_access_copy_missing, 'no JSON access copy; reads answer 404 and no title')
      elsif @work.decorate.plain_title.blank?
        add(:repairable, :untitled, 'the MODS has no title; nothing can find or name this Work')
      end
      return add(:repairable, :descriptive_file_set_missing, 'a MODS PUT recreates it') if descriptive_file_set.nil?

      check_bytes(@work.mods_blob, missing: :mods_xml_missing, label: 'MODS XML')
    end

    def check_placement
      parent = @work.parent
      if parent.nil?
        code = @work.a_member_of.present? ? :parent_missing : :orphaned
        return add(:repairable, code, 'no parent Collection; absent from every listing and ancestry')
      end
      add(:repairable, :wrong_parent_type, "filed under #{parent.class} #{parent.noid}") unless parent.is_a?(Collection)
      return unless parent.tombstoned && !@work.tombstoned

      add(:repairable, :live_under_withdrawn, "readable inside withdrawn #{parent.noid}")
    end

    # Admins pass every gate, so these show up only for the people the ACL is for.
    def check_permissions
      unless @work.edit_groups.include?(Permissions::STAFF_EDIT_GROUP)
        add(:repairable, :staff_edit_missing, 'staff cannot edit')
      end
      add(:repairable, :no_depositor, 'no depositor; the owner cannot edit') if @work.depositor.blank?
      add(:advisory, :private, 'no read group; only editors can see it') if @work.read_groups.empty?
    end

    def check_content
      pages = @work.page_file_sets
      return add(:repairable, :no_content, 'no content FileSet; nothing to view or download') if pages.empty?

      pages.each do |fs|
        dangling = fs.member_ids.size - fs.files.compact.size
        add(:repairable, :dangling_member, "#{dangling} member id(s) name no Blob", fs.noid) if dangling.positive?
        blobs = fs.content_files
        next add(:repairable, :empty_file_set, 'content FileSet holds no Blob', fs.noid) if blobs.empty?

        blobs.each { |blob| check_blob(blob) }
      end
    end

    def check_blob(blob)
      if blob.mime_type.blank? || blob.original_filename.blank?
        add(:repairable, :blob_metadata_missing, 'no MIME type or filename; download guesses both', blob.noid)
      end
      check_bytes(blob, missing: :binary_missing, label: 'binary')
    end

    def check_bytes(blob, missing:, label:)
      return add(:fatal, missing, "no #{label} Blob") if blob.nil?
      return add(:repairable, :blob_unlinked, "#{label} is unlinked", blob.noid) if blob.file_identifiers.empty?

      blob.file
    rescue Valkyrie::StorageAdapter::FileNotFound
      add(:fatal, missing, "#{label} is not in storage", blob.noid)
    end

    def check_lifecycle
      add(:advisory, :withdrawn, "withdrawn: #{@work.tombstone_reason}") if @work.tombstoned
      add(:advisory, :in_progress, "deposit still open since #{@work.created_at&.to_date}") if @work.in_progress
      add(:repairable, :flagged_incomplete, "incomplete: #{@work.incomplete_reason}") if @work.incomplete
      add(:advisory, :no_handle, 'no handle') if @work.handle.blank? && !@work.in_progress
    end

    def check_index
      Atlas.index_adapter.query_service.find_by(id: @work.id)
    rescue Valkyrie::Persistence::ObjectNotFoundError
      add(:repairable, :not_indexed, 'no Solr document; search and OAI miss it until a reindex')
    end

    # The objects Postgres names, validated in place. The pool-wide index the
    # offline tool builds reads every object, which a per-Work check cannot pay.
    #
    # A recorded failed check is altered bytes, the loss a FIXITY=1 mismatch
    # finds. Only an object's latest check counts, so a passing re-check clears it.
    def check_disk
      pool = OcflHealth::Pool.new(Valkyrie.config.storage_adapter.storage_roots.values.map(&:base_path))
      failed = FixityResult.failed_keys(@work.preserved_resources.map(&:noid))
      @work.preserved_resources.each do |resource|
        version = failed[resource.noid]
        add(:fatal, :fixity_failed, "the latest recorded check, of #{version}, failed", resource.noid) if version
        path = pool.object_path(resource.noid)
        next add(:repairable, :envelope_missing, 'no OCFL object; rewrite the envelope', resource.noid) if path.nil?

        validator = OcflHealth::ObjectValidator.new(path, key: resource.noid, fixity: @fixity).call
        @findings.concat(validator.findings)
        check_envelope_current(resource, validator)
      end
    end

    def check_envelope_current(resource, validator)
      envelope = OcflHealth::Envelope.read(validator)
      @findings.concat(envelope.findings)
      return if envelope.graph.nil?

      live = resource.graph_payload.as_json
      drift = (envelope.graph.keys | live.keys).reject { |key| same?(envelope.graph[key], live[key]) }
      return if drift.empty?

      add(:repairable, :envelope_stale, "the on-disk envelope differs from Postgres in #{drift.join(', ')}",
          resource.noid)
    end

    # Member order carries no meaning -- page order is `position` -- so an
    # envelope listing the same members in another order is still current.
    def same?(disk, live)
      return disk.sort == live.sort if disk.is_a?(Array) && live.is_a?(Array)

      disk == live
    end
end
