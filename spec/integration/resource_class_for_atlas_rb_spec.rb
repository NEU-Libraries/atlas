# frozen_string_literal: true

require 'rails_helper'

# atlas_rb 1.17.0 — AtlasRb::Resource.class_for, and Resource.find reporting a
# type string that resolves to a class in the gem's namespace. Consumers
# dispatch on that string, so a type the namespace cannot resolve is a
# NameError in the caller.
#
# This layer is the only one that can prove the mapping: Atlas's wire key, the
# typed redirect and the gem's class lookup live in three different systems,
# and a mocked spec would assert the map against itself. Every type the
# resolver covers is exercised, so a type added to Atlas cannot ship without
# landing in TYPE_MAP.
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
      expect(AtlasRb::Resource.class_for(found['klass'])).to eq(AtlasRb::FileSet)
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
        AtlasRb::Resource.class_for(AtlasRb::Resource.find(noid, nuid: admin_nuid)['klass'])
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

  describe 'Resource.class_for' do
    it 'accepts all three spellings of one type' do
      expect(AtlasRb::Resource.class_for('file_set')).to eq(AtlasRb::FileSet)
      expect(AtlasRb::Resource.class_for('FileSet')).to eq(AtlasRb::FileSet)
      expect(AtlasRb::Resource.class_for('File_set')).to eq(AtlasRb::FileSet)
    end

    it 'accepts a symbol' do
      expect(AtlasRb::Resource.class_for(:work)).to eq(AtlasRb::Work)
    end

    it 'covers the Compilation the generic resolver does not' do
      expect(AtlasRb::Resource.class_for('Compilation')).to eq(AtlasRb::Compilation)
    end

    it 'raises on a type the gem defines no class for' do
      expect { AtlasRb::Resource.class_for('Sandwich') }
        .to raise_error(ArgumentError, /unknown Atlas resource type: "Sandwich"/)
    end
  end
end
