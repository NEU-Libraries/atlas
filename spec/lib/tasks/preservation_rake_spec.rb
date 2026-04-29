# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'atlas:preservation rake tasks' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('atlas:preservation:backfill_envelopes')
  end

  before(:each) { Rake::Task['atlas:preservation:backfill_envelopes'].reenable }
  after { Atlas.persister.wipe! }

  def envelope_files_for(noid)
    object_root = Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
    return [] unless object_root.exist?

    Dir.glob(object_root.join('v*', 'content', '*.json').to_s).map { |p| File.basename(p) }.uniq.sort
  end

  describe 'atlas:preservation:backfill_envelopes' do
    it 'emits envelopes for resources that don\'t have them yet' do
      # Bypass Creators (which emit envelopes) to simulate pre-Phase-2 state.
      community = Atlas.persister.save(resource: Community.new)
      collection = Atlas.persister.save(resource: Collection.new(a_member_of: [community.id]))

      expect(envelope_files_for(community.noid)).to be_empty
      expect(envelope_files_for(collection.noid)).to be_empty

      Rake::Task['atlas:preservation:backfill_envelopes'].invoke

      expect(envelope_files_for(community.noid)).to include('relationships.json', 'permissions.json')
      expect(envelope_files_for(collection.noid)).to include('relationships.json', 'permissions.json')
    end

    it 'emits properties.json (not relationships.json) for Blob resources' do
      blob = Atlas.persister.save(resource: Blob.new(use: Role.original_file.name))

      Rake::Task['atlas:preservation:backfill_envelopes'].invoke

      expect(envelope_files_for(blob.noid)).to include('properties.json', 'permissions.json')
      expect(envelope_files_for(blob.noid)).not_to include('relationships.json')
    end

    it 'is idempotent: re-running does not raise' do
      Atlas.persister.save(resource: Community.new)

      Rake::Task['atlas:preservation:backfill_envelopes'].invoke
      Rake::Task['atlas:preservation:backfill_envelopes'].reenable

      expect { Rake::Task['atlas:preservation:backfill_envelopes'].invoke }.not_to raise_error
    end

    it 'continues past per-resource failures' do
      Atlas.persister.save(resource: Community.new)
      bad = Atlas.persister.save(resource: Community.new)

      allow_any_instance_of(Community).to receive(:write_preservation_envelope!) do |instance|
        raise StandardError, 'boom' if instance.noid == bad.noid
      end

      expect { Rake::Task['atlas:preservation:backfill_envelopes'].invoke }.not_to raise_error
    end
  end
end
