# frozen_string_literal: true

module Modsable
  extend ActiveSupport::Concern
  include MODSBuilder
  include MODSToJson
  include FileHelper

  # `defined?` rather than `@mods ||=`: a resource with no access-copy row
  # memoizes the nil, so the two-or-three MODS reads a single render does
  # (plain_title, plain_description, permanent_url) cost one query, not one
  # each. Index views render a page of these, so the difference is per row.
  def mods
    return @mods if defined?(@mods)

    @mods = Metadata::MODS.find_by(valkyrie_id: noid)
  end

  # Seed the `mods` memo from a batch read, so a page of rows costs one
  # metadata_mods query instead of one per row. Pass nil for a resource the
  # batch found no row for — that is a legitimate answer and gets memoized.
  # Read-path only: nothing here invalidates, and `mods_json=` reseeds.
  def preload_mods(record)
    @mods = record
  end

  def mods_xml
    return mods_template if mods_blob&.file.blank?

    Nokogiri::XML(mods_blob.file.read, &:noblanks).to_s
  end

  def mods_xml=(raw_xml)
    blob = mods_blob || create_mods_blob
    blob.file_identifiers += [create_file(write_tmp_xml(raw_xml), blob, 'descMetadata.xml').version_id]
    Atlas.persister.save(resource: blob)

    self.mods_json = raw_xml
  end

  def mods_blob
    descriptive_metadata_file_set&.files&.first
  end

  # Whether `mods_xml=` has somewhere to write. Every resource built through
  # its creator gets the descriptive-metadata FileSet, so a false here is a
  # resource assembled by hand — which callers that write MODS opportunistically
  # have to check, because the write raises rather than inventing the FileSet.
  def mods_writable?
    descriptive_metadata_file_set.present?
  end

  # Writes the access copy, and drops the cached responses that project it.
  #
  # The eviction lives HERE, not in the persister, because this row lands
  # before the persister sees anything — `mods_xml=` writes the blob, calls
  # this, and only then saves the resource. A hook downstream would read the
  # new title as though it had always been there and never notice the change.
  #
  # A container's title is embedded in every descendant Work's `ancestors`, so
  # renaming one invalidates their cached bodies too. That cascade is a Solr
  # lookup and is only paid when the title actually moved — comparing the
  # composed title parts before and after costs one hash comparison, and
  # container renames are rare next to the metadata writes that leave the title
  # alone.
  def mods_json=(raw_xml)
    record = Metadata::MODS.find_or_create_by(valkyrie_id: noid)
    previous_title = record.main_title&.attributes
    record.json_attributes = convert_xml_to_json(raw_xml)
    record.save!
    @mods = record

    ResponseCache.evict(noid)
    return unless is_a?(Collection) || is_a?(Community)
    return if record.main_title&.attributes == previous_title

    ResponseCache.evict_many(DescendantWorkNoidsQuery.call(self))
  end

  private

    def descriptive_metadata_file_set
      children.find { |fs| fs.type == Classification.descriptive_metadata.name }
    end

    # Fail before the Blob is persisted, not after: a resource with no
    # descriptive-metadata FileSet has nothing to attach one to, and saving
    # first would leave the unreferenced Blob behind in Postgres and Solr.
    def create_mods_blob
      fs = descriptive_metadata_file_set
      raise "#{noid} has no descriptive-metadata FileSet to hold MODS" if fs.nil?

      blob = Atlas.persister.save(resource: Blob.new(use: Role.descriptive_metadata.name))
      fs.member_ids += [blob.id]
      fs = Atlas.persister.save(resource: fs)
      blob.write_preservation_envelope!
      fs.write_preservation_envelope!
      blob
    end

    def write_tmp_xml(raw_xml)
      xml_path = Rails.root.join('tmp', "#{Time.now.to_f.to_s.gsub!('.', '-')}.xml").to_s
      File.write(xml_path, raw_xml)
      xml_path
    end
end
