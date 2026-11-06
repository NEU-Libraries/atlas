# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Delegates', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  path '/delegates/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Delegate'

    get 'Retrieve a Delegate' do
      tags 'Delegates'
      produces 'application/json'
      description <<~DESC
        Returns a binary-less Delegate resource — carries the same
        structural metadata as a Blob (use, label, mime_type) plus a
        generic `uri` pointing at where the asset can be fetched
        (an IIIF URL for image roles).
      DESC

      response '200', 'delegate found' do
        let(:delegate) do
          DelegateCreator.call(
            resource_id: work.id,
            use:         Role.thumbnail_image.name,
            uri:         'https://iiif.example/iiif/2/abc/full/!200,200/0/default.jpg'
          )
        end
        let(:id) { delegate.noid }
        schema '$ref' => '#/components/schemas/Delegate'
        run_test!
      end

      tombstoned_record_responses(full: 'Delegate', withheld: 'Tombstoned') do
        let(:id) do
          tombstoned!(DelegateCreator.call(resource_id: public_work!.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')).noid
        end
      end

      tombstoned_record_responses(full: 'Delegate', withheld: 'Tombstoned') do
        let(:id) do
          work = public_work!
          delegate = DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')
          tombstoned!(Work.find(work.noid))
          delegate.noid
        end
      end
    end
  end
end
