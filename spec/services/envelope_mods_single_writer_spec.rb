# frozen_string_literal: true

require 'rails_helper'

# Writes of one resource's envelope, MODS or Darwin Core run one at a time
# under its advisory lock. See docs/write-safety.md.
#
# Transactional tests pin one connection that every thread shares, and a
# session advisory lock is re-entrant within one session, so this file turns
# them off to give each thread its own connection, as Puma threads have. Each
# race slows the first writer at the point where, without the lock, the second
# writer would land in between.
RSpec.describe 'Envelope and metadata writes of one resource' do
  self.use_transactional_tests = false

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:mods)       { Rails.root.join('spec/fixtures/files/work-mods.xml').read }
  let(:dwc)        { Rails.root.join('spec/fixtures/files/dwc.xml').read }

  def mods_titled(title) = mods.sub("<mods:title>What's New</mods:title>", "<mods:title>#{title}</mods:title>")

  def in_threads(*blocks)
    blocks.map do |block|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }
    end.map(&:value)
  end

  def slowed(target, method)
    allow(target).to receive(method).and_wrap_original do |original, *args, **kw|
      original.call(*args, **kw).tap { sleep 0.5 }
    end
    target
  end

  def a_moment_later(&block) = -> { sleep(0.1).then { block.call } }

  def on_disk_permissions
    root = TestStorage.root.join(work.noid[0..1], work.noid[2..3], work.noid)
    inventory = JSON.parse(File.read(root.join('inventory.json')))
    state = inventory.dig('versions', inventory['head'], 'state')
    digest, = state.find { |_digest, paths| paths.include?('permissions.json') }
    JSON.parse(File.read(root.join(inventory.dig('manifest', digest).first)))
  end

  def stored_title(resource)
    doc = Nokogiri::XML(resource.class.find(resource.id).mods_xml)
    doc.at_xpath('//mods:title', mods: 'http://www.loc.gov/mods/v3').text
  end

  def access_copy_title(resource) = Metadata::MODS.plain_titles_for([resource.noid])[resource.noid]

  before { work }

  # These writes commit, so the rows a wipe! leaves behind outlive the example.
  after do
    Atlas.persister.wipe!
    StorageFootprint.delete_all
    Metadata::MODS.delete_all
    Metadata::METS.delete_all
    Metadata::DarwinCore.delete_all
  end

  describe 'two envelope writes of one Work' do
    it 'leave the later save on disk when the earlier writer is slower' do
      earlier = slowed(PreservationEnvelopeWriter.new(resource: work), :staged_in)

      in_threads(
        -> { earlier.call },
        a_moment_later do
          fresh = Work.find(work.noid)
          fresh.read_groups = ['race:later']
          Atlas.persister.save(resource: fresh).write_preservation_envelope!
        end
      )

      expect(on_disk_permissions['read']).to eq(['race:later'])
    end
  end

  describe 'two MODS uploads to one Work' do
    it 'leave the XML and the access copy holding the same document' do
      earlier = slowed(Work.find(work.noid), :convert_xml_to_json)

      in_threads(
        -> { earlier.mods_xml = mods_titled('Earlier') },
        a_moment_later { Work.find(work.noid).mods_xml = mods_titled('Later') }
      )

      expect(access_copy_title(work)).to start_with(stored_title(work))
    end
  end

  describe 'two edits built from the stored MODS' do
    it 'keep both, because each reads the document the other wrote' do
      add_note = lambda do |note|
        lambda do |xml|
          doc = Nokogiri::XML(xml)
          doc.root.add_child(%(<mods:note xmlns:mods="http://www.loc.gov/mods/v3">#{note}</mods:note>))
          doc.to_s
        end
      end
      earlier = Work.find(work.noid)
      allow(earlier).to receive(:mods_xml).and_wrap_original { |original| original.call.tap { sleep 0.5 } }

      in_threads(
        -> { earlier.update_mods_xml(&add_note.call('earlier')) },
        a_moment_later { Work.find(work.noid).update_mods_xml(&add_note.call('later')) }
      )

      expect(Work.find(work.noid).mods_xml).to include('earlier', 'later')
    end
  end

  describe 'a whole-document MODS write racing a mint' do
    it 'keeps the handle the mint saves while the write holds an older copy' do
      hdl = "/mods:mods/mods:identifier[@type='hdl']"
      stripped = Nokogiri::XML(work.mods_xml).tap { |doc| doc.xpath(hdl, NEU::MODS::NAMESPACE).each(&:remove) }.to_s
      client = instance_double(HandleClient, configured?: true, mint: "DRSDEV/#{work.noid}")
      earlier = Work.find(work.noid)
      allow(earlier).to receive(:mods_xml=).and_wrap_original { |original, xml| sleep(0.5).then { original.call(xml) } }

      in_threads(
        -> { earlier.replace_mods_xml(stripped) },
        a_moment_later { HandleMinter.call(work: work, client: client, public_base: 'https://repository.example.edu') }
      )

      stored = Nokogiri::XML(Work.find(work.noid).mods_xml).at_xpath(hdl, NEU::MODS::NAMESPACE)
      expect(stored&.text).to eq("https://hdl.handle.net/DRSDEV/#{work.noid}")
    end
  end

  describe 'two Darwin Core uploads to one Work' do
    it 'leave the XML and the access copy holding the same document' do
      Work.find(work.noid).darwin_core_xml = dwc
      earlier = Work.find(work.noid)
      allow(Metadata::DarwinCore).to receive(:find_or_create_by).and_wrap_original do |original, **kw|
        sleep 0.5 if Thread.current[:slow]
        original.call(**kw)
      end

      in_threads(
        lambda do
          Thread.current[:slow] = true
          earlier.darwin_core_xml = dwc.sub('Perognathus inornatus inornatus', 'Earlier name')
        end,
        a_moment_later do
          Work.find(work.noid).darwin_core_xml = dwc.sub('Perognathus inornatus inornatus', 'Later name')
        end
      )

      stored = Work.find(work.noid).darwin_core_xml[/Earlier name|Later name/]
      expect(Metadata::DarwinCore.find_by(valkyrie_id: work.noid).json_attributes.to_s).to include(stored)
    end
  end
end
