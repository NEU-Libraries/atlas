# frozen_string_literal: true

require 'rails_helper'

describe WorksController, type: :controller do
  render_views

  after :each do
    Atlas.persister.wipe!
  end

  describe 'GET #show' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }
    it 'returns the work details' do
      title = 'Test Title'
      work.plain_title = title
      get :show, params: { id: work.noid }, as: :json
      expect(response).to have_http_status(:success)

      json_response = response.parsed_body
      expect(json_response['work']['id']).to eq(work.noid)
      expect(json_response['work']['title']).to eq(title)
      expect(work.parent.filtered_children.count).to eq(1)
    end
  end

  describe 'GET #mods' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    it 'displays MODS metadata in JSON for the work' do
      title = 'Mods Test'
      work.plain_title = title
      get :mods, params: { id: work.noid }, as: :json
      expect(response).to have_http_status(:success)
      json_response = response.parsed_body
      expect(json_response['work']).not_to be_empty
      expect(json_response['work']['mods']).not_to be_empty
      expect(json_response['work']['mods']['main_title']['title']).to eq(title)
    end

    it 'displays MODS metadata in HTML for the work' do
      title = 'HTML Test'
      work.plain_title = title
      get :mods, params: { id: work.noid }, as: :html
      expect(response).to have_http_status(:success)
      expect(response.body).to include(title)
    end
  end

  describe 'GET #index' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    context 'when works exist' do
      it 'returns a paginated list of all works' do
        12.times do
          WorkCreator.call(parent_id: collection.noid)
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['works']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
  end

  describe 'POST #create' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'creates a work with provided collection id as parent' do
      post :create, params: { collection_id: collection.noid }, as: :json
      expect(response).to have_http_status(:success)
      expect(Atlas.query.find_all_of_model(model: Work).count).to eq(1)
      # TODO: Test id is returned and resolves to resource
    end
  end

  describe 'PATCH #update' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    it 'updates a work with provided XML binary' do
      patch :update, params: { id: work.noid, binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }, as: :json
      expect(response).to have_http_status(:success)
      expect(work.decorate.plain_title).to eq("What's New - How We Respond to Disaster, Episode 1")
    end
  end

  describe 'DELETE #destroy' do
    let(:community) { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    context 'when work exists' do
      it 'destroys the work' do
        delete :destroy, params: { id: work.noid }, as: :json
        expect(response).to have_http_status(:success)
        expect(Work.find(work.noid)).to be_nil
      end
    end
  end

  describe 'POST #tombstone' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }

    it 'tombstones a Work regardless of attached FileSets' do
      # Works always tombstone — children (FileSets/Blobs) ride along.
      post :tombstone, params: { id: work.noid }, as: :json

      expect(response).to have_http_status(:success)
      json = response.parsed_body['work']
      expect(json['tombstoned']).to be(true)
      expect(json['tombstoned_at']).to be_present

      reloaded = Work.find(work.noid)
      expect(reloaded.tombstoned).to be(true)
      expect(reloaded.tombstoned_at).to be_present
    end
  end

  describe 'POST #restore' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work) do
      w = WorkCreator.call(parent_id: collection.noid)
      w.tombstoned = true
      w.tombstoned_at = Time.current
      w.tombstoned_by = '000000002'
      Atlas.persister.save(resource: w)
    end

    it 'clears tombstone fields' do
      post :restore, params: { id: work.noid }, as: :json

      expect(response).to have_http_status(:success)
      reloaded = Work.find(work.noid)
      expect(reloaded.tombstoned).to be(false)
      expect(reloaded.tombstoned_at).to be_nil
      expect(reloaded.tombstoned_by).to be_nil
    end
  end

  # Optimistic-lock handling on the retry-safe Delegate-attach actions.
  # See StaleObjectRetry + the 409 rescue_from in ApplicationController.
  describe 'StaleObjectError handling on retry-safe actions' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }
    let(:uri)        { 'https://iiif.example/iiif/2/abc/full/!85,85/0/default.jpg' }

    # Make backoff sleeps instantaneous so the retry path doesn't add wall time.
    before { allow(controller).to receive(:sleep) }

    describe 'PATCH #update_thumbnails' do
      it 'retries a transient conflict and still lands the Delegate' do
        calls = 0
        allow(DelegateUpdater).to receive(:call).and_wrap_original do |original, **kwargs|
          calls += 1
          raise Valkyrie::Persistence::StaleObjectError if calls == 1

          original.call(**kwargs)
        end

        patch :update_thumbnails, params: { id: work.noid, thumbnail: uri }, as: :json

        expect(response).to have_http_status(:success)
        expect(calls).to be >= 2
        expect(response.parsed_body.dig('work', 'thumbnail')).to eq(uri)
      end

      it 'surfaces a 409 stale_resource envelope when retries exhaust' do
        allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)

        patch :update_thumbnails, params: { id: work.noid, thumbnail: uri }, as: :json

        expect(response).to have_http_status(:conflict)
        json = response.parsed_body
        expect(json['error']).to eq('stale_resource')
        expect(json['resource_id']).to eq(work.noid)
        expect(json['action']).to eq('update_thumbnails')
        expect(json['message']).to be_present
      end
    end

    describe 'PATCH #update_image_derivatives' do
      it 'surfaces a 409 stale_resource envelope when retries exhaust' do
        allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)

        patch :update_image_derivatives, params: { id: work.noid, small: uri }, as: :json

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body['error']).to eq('stale_resource')
        expect(response.parsed_body['action']).to eq('update_image_derivatives')
      end
    end

    describe 'POST #complete' do
      it 'retries a transient conflict and still completes' do
        work # persist the whole chain before stubbing save
        calls = 0
        allow(Atlas.persister).to receive(:save).and_wrap_original do |original, **kwargs|
          calls += 1
          raise Valkyrie::Persistence::StaleObjectError if calls == 1

          original.call(**kwargs)
        end

        post :complete, params: { id: work.noid }, as: :json

        expect(response).to have_http_status(:success)
        expect(calls).to be >= 2
        expect(response.parsed_body.dig('work', 'in_progress')).to be false
      end

      it 'surfaces a 409 stale_resource envelope when retries exhaust' do
        work # persist before stubbing so creator saves don't hit the stub
        allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)

        post :complete, params: { id: work.noid }, as: :json

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body['error']).to eq('stale_resource')
        expect(response.parsed_body['action']).to eq('complete')
      end
    end
  end

  # Retry-unsafe actions surface the conflict immediately (no retry) — a
  # silent retry could clobber a concurrent caller's genuinely different
  # intent. They still get the structured 409 envelope.
  describe 'StaleObjectError handling on retry-unsafe actions' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }

    it 'PATCH #update surfaces 409 immediately without retrying' do
      work # persist before stubbing save
      calls = 0
      allow(Atlas.persister).to receive(:save) do
        calls += 1
        raise Valkyrie::Persistence::StaleObjectError
      end

      patch :update, params: { id: work.noid, metadata: { title: 'Conflicting' } }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(calls).to eq(1) # surfaced on the first conflict, no retry
      json = response.parsed_body
      expect(json['error']).to eq('stale_resource')
      expect(json['action']).to eq('update')
    end

    it 'POST #tombstone surfaces 409 immediately' do
      work # persist before stubbing save
      allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)

      post :tombstone, params: { id: work.noid }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error']).to eq('stale_resource')
      expect(response.parsed_body['action']).to eq('tombstone')
    end
  end

  describe 'POST #add_linked_member (admin-only authz gate)' do
    # Linking a Work into additional Collections is an admin-only structural
    # mutation: edit rights are not sufficient, even on BOTH the Work and the
    # target Collection. The linker carries a custom edit group (not the
    # default staff group) so we can grant explicit edit rights and prove they
    # still don't unlock the link.
    let(:edit_group) { 'northeastern:drs:special-linkers' }
    let!(:linker) do
      User.create!(email: "linker-#{SecureRandom.hex(4)}@example.invalid",
                   password: SecureRandom.hex(16), nuid: '000000778',
                   name: 'User, Linker', role: :privileged, groups: [edit_group])
    end

    let(:community)  { CommunityCreator.call }
    let(:home)       { CollectionCreator.call(parent_id: community.noid) }
    let(:target)     { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: home.noid) }

    def grant!(resource)
      resource.add_edit_group(edit_group)
      Atlas.persister.save(resource: resource)
    end

    it 'forbids an edit-rights principal even with edit rights on BOTH work and target' do
      grant!(work)
      grant!(target)
      request.headers['User'] = "NUID #{linker.nuid}"

      post :add_linked_member, params: { id: work.noid, collection_id: target.noid }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Array(Work.find(work.noid).a_linked_member_of)).to be_empty
    end

    it 'allows linking for an admin' do
      # Default controller principal is the admin fixture (NUID 000000004).
      post :add_linked_member, params: { id: work.noid, collection_id: target.noid }, as: :json

      expect(response).to have_http_status(:success)
      expect(Array(Work.find(work.noid).a_linked_member_of).map(&:to_s)).to include(target.id.to_s)
    end
  end
end
