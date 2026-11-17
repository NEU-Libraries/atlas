# frozen_string_literal: true

require 'rails_helper'

# Each save's Solr write, and each reindex, indexes what Postgres holds, one
# write per resource at a time. See docs/write-safety.md.
#
# Transactional tests pin one connection that every thread shares, and a
# session advisory lock is re-entrant within one session, so this file turns
# them off to give each thread its own connection, as Puma threads have.
RSpec.describe 'Solr writes of one resource' do
  self.use_transactional_tests = false

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def in_threads(*blocks)
    blocks.map do |block|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }
    end.map(&:value)
  end

  def a_moment_later(&block) = -> { sleep(0.1).then { block.call } }

  def indexed_read_groups(resource)
    Atlas.index_adapter.connection
         .get('select', params: { q: %(id:"#{resource.id}"), fl: 'read_access_group_ssim' })
         .dig('response', 'docs', 0, 'read_access_group_ssim')
  end

  def indexed?(resource)
    Atlas.index_adapter.connection.get('select', params: { q: %(id:"#{resource.id}") })
         .dig('response', 'numFound').positive?
  end

  def save_with_read_group(group)
    Atlas.persister.save(resource: Work.find(work.noid).tap { |w| w.read_groups = [group] })
  end

  before { work }

  # These writes commit, so the rows a wipe! leaves behind outlive the example.
  after do
    Atlas.persister.wipe!
    StorageFootprint.delete_all
    Metadata::MODS.delete_all
    Metadata::METS.delete_all
  end

  describe 'two saves of one Work whose Solr writes overlap' do
    it 'leave the later save in Solr when the earlier save indexes slower' do
      allow(Atlas.persister.index).to receive(:save).and_wrap_original do |original, **kw|
        sleep 0.5 if Thread.current[:slow]
        original.call(**kw)
      end

      in_threads(
        lambda do
          Thread.current[:slow] = true
          save_with_read_group('race:earlier')
        end,
        a_moment_later { save_with_read_group('race:later') }
      )

      expect(indexed_read_groups(work)).to eq(['race:later'])
    end
  end

  describe 'a reindex from a copy read before a later save' do
    it 'indexes the later save' do
      stale = Work.find(work.noid)
      save_with_read_group('race:later')

      Atlas.reindex(stale)

      expect(indexed_read_groups(work)).to eq(['race:later'])
    end
  end

  describe 'a reindex of a purged resource' do
    it 'brings back no Solr document' do
      stale = Work.find(work.noid)
      ResourcePurger.call(resource: stale)

      Atlas.reindex(stale)

      expect(indexed?(stale)).to be(false)
    end
  end
end
