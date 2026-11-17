# frozen_string_literal: true

require 'rails_helper'

# Adding a Compilation member is idempotent, including when two adds of the same
# member arrive at once: find_or_create_by! falls back to create_or_find_by!, so
# the add that loses the insert reads the row the other made. See
# docs/compilations.md.
#
# Transactional tests pin one connection that every thread shares, so this file
# turns them off and sends each request through the Rack app in its own thread,
# as Puma does.
RSpec.describe 'Two adds of the same Compilation member at once', type: :request do
  self.use_transactional_tests = false

  let(:community)   { CommunityCreator.call }
  let(:collection)  { CollectionCreator.call(parent_id: community.noid) }
  let(:work)        { WorkCreator.call(parent_id: collection.noid) }
  let(:compilation) { Compilation.create!(title: 'Race', depositor: DefaultAuthHeaders::ADMIN_NUID) }

  def add_in_thread(path, body)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Rack::MockRequest.new(Rails.application).post(
          path, input: body.to_json, 'CONTENT_TYPE' => 'application/json',
                'HTTP_AUTHORIZATION' => "Bearer #{DefaultAuthHeaders.admin_assertion}"
        ).status
      end
    end
  end

  # Both requests look for the row before either inserts it.
  def slow_validation(model)
    allow_any_instance_of(model).to receive(:resource_noid_resolves_to_expected_type) { sleep 0.3 }
  end

  after do
    Compilation.delete_all
    AuditEvent.delete_all
    User.where(nuid: DefaultAuthHeaders::ADMIN_NUID).delete_all
    Atlas.persister.wipe!
    StorageFootprint.delete_all
    Metadata::MODS.delete_all
  end

  {
    'included_works'       => [Compilation::WorkInclusion, :work_id, -> { work.noid }],
    'included_collections' => [Compilation::CollectionInclusion, :collection_id, -> { collection.noid }],
    'exclusions'           => [Compilation::Exclusion, :work_id, -> { work.noid }]
  }.each do |line, (model, param, member)|
    it "answers 200 to both, and adds one #{line} row" do
      noid = instance_exec(&member)
      path = "/compilations/#{compilation.noid}/#{line}"
      slow_validation(model)

      statuses = Array.new(2) { add_in_thread(path, { param => noid }) }.map(&:value)

      expect(statuses).to eq([200, 200])
      expect(model.where(compilation: compilation, resource_noid: noid).count).to eq(1)
    end
  end
end
