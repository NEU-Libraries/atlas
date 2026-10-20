# frozen_string_literal: true

require 'rails_helper'

# Resource.find reports a type string, and Mash#resource_class resolves it
# through the gem's type registry. Consumers dispatch on that class, so a type
# the registry cannot resolve is an ArgumentError in the caller.
#
# This layer is the only one that can prove the mapping: Atlas's wire key, the
# typed redirect and the gem's registry live in three different systems, and a
# mocked spec would assert the registry against itself. Every type the resolver
# covers is exercised, so a type added to Atlas cannot ship without a class in
# the gem.
RSpec.describe 'Generic resource resolution via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:file_set)   { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
  let(:blob)       { BlobCreator.call(work_id: work.noid, path: fixture, original_filename: 'example.bin') }
  let(:person)     { PersonCreator.call(nuid: '001234567', display_name: 'Doe, Jane') }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }

  let(:delegate) do
    DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,
                         uri: 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
  end

  # The Ruby class name Solr carries for a resource — the other vocabulary
  # Cerberus receives the same type fact in.
  def internal_resource_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'internal_resource_tesim' }
    ).dig('response', 'docs').first&.fetch('internal_resource_tesim', nil)&.first
  end

  describe 'Resource.find' do
    it 'reports a FileSet as "FileSet", which resolves to a class' do
      found = AtlasRb::Resource.find(file_set.noid, nuid: admin_nuid)

      expect(found['klass']).to eq('FileSet')
      expect(found.resource_class).to eq(AtlasRb::FileSet)
      expect(found['resource']['id']).to eq(file_set.noid)
    end

    it 'reports a resolvable class name for every type the resolver covers' do
      expected = {
        work.noid       => AtlasRb::Work,
        collection.noid => AtlasRb::Collection,
        community.noid  => AtlasRb::Community,
        file_set.noid   => AtlasRb::FileSet,
        blob.noid       => AtlasRb::Blob,
        delegate.noid   => AtlasRb::Delegate,
        person.noid     => AtlasRb::Person
      }

      resolved = expected.keys.index_with do |noid|
        AtlasRb::Resource.find(noid, nuid: admin_nuid).resource_class
      end

      expect(resolved).to eq(expected)
    end

    it 'reports the same spelling Solr indexes as internal_resource' do
      found = AtlasRb::Resource.find(file_set.noid, nuid: admin_nuid)

      expect(found['klass']).to eq(internal_resource_in_solr(file_set))
    end

    # Blob's typed route is /files/:id, so ResourcesController#show has to name
    # the path itself: the polymorphic redirect would need a blob_url, which no
    # route defines.
    it 'resolves a Blob rather than failing on the typed redirect' do
      found = AtlasRb::Resource.find(blob.noid, nuid: admin_nuid)

      expect(found['klass']).to eq('Blob')
      expect(found['resource']['id']).to eq(blob.noid)
      expect(found['resource']['original_filename']).to eq('example.bin')
    end

    # The resolver's coverage is narrower than the class hierarchy, so nil
    # carries two meanings and a caller cannot tell them apart.
    it 'returns nil for a Compilation, which is not Valkyrie-backed in Atlas' do
      set = AtlasRb::Compilation.create('HIST 1101 readings', nuid: admin_nuid)

      expect(AtlasRb::Resource.find(set['id'], nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Compilation.find(set['id'], nuid: admin_nuid)['id']).to eq(set['id'])
    end

    it 'returns nil for an unknown id' do
      expect(AtlasRb::Resource.find('does-not-exist', nuid: admin_nuid)).to be_nil
    end
  end

  # Atlas builds klass on every payload but Resource.find's, so only a live
  # server shows that the gem can resolve what Atlas sends.
  describe 'resource_class on an ancestors node' do
    it 'resolves each ancestor of a Work, root first' do
      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)

      expect(found['ancestors'].map(&:resource_class)).to eq([AtlasRb::Community, AtlasRb::Collection])
    end
  end

  # The gem states the MODS-editable types by hand, because Atlas does not put
  # them on the wire.
  describe 'mods_editable?' do
    it 'agrees with Atlas on which types take a MODS write' do
      editable = AtlasRb::Resource::TYPES.values.uniq.select(&:mods_editable?)

      expect(editable.map { |k| k.name.split('::').last })
        .to match_array(ResourcesController::TYPED_IVARS.keys.map(&:name))
    end
  end
end
