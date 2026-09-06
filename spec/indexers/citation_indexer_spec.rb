# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CitationIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # Build a Work whose #mods returns a controlled JSON access copy, so the
  # projection logic is asserted without depending on exact NEU::MODS display
  # strings (those are exercised end-to-end below through the real fixture).
  def work_with_mods(names: [], topical_subjects: [], date_created: nil)
    mods = Metadata::MODS.new(
      names:            names.map { |attrs| Metadata::Fields::Name.new(**attrs) },
      topical_subjects: topical_subjects,
      date_created:     date_created
    )
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }
  end

  # Re-read the projected fields straight off the Work's Solr doc.
  def citation_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select',
      params: { q: %(id:"#{resource.id}"), fl: 'creator_ssim,pub_date_ssim' }
    ).dig('response', 'docs').first
  end

  describe '#to_solr' do
    it 'returns an empty hash for a Work with no citation metadata' do
      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it 'projects creator-role names onto creator_ssim and excludes other roles' do
      resource = work_with_mods(names: [
                                  { name: 'Lee, Wen-Han', roles: ['Creator'] },
                                  { name: 'Northeastern University. Libraries', roles: ['creator'] },
                                  { name: 'Smith, Editor', roles: ['Contributor'] }
                                ])

      expect(described_class.new(resource: resource).to_solr[:creator_ssim])
        .to contain_exactly('Lee, Wen-Han', 'Northeastern University. Libraries')
    end

    it 'projects the publication year (single value, as a string) onto pub_date_ssim' do
      resource = work_with_mods(date_created: Time.zone.parse('2017-09-19'))

      expect(described_class.new(resource: resource).to_solr[:pub_date_ssim]).to eq('2017')
    end

    it 'de-duplicates and drops blank creators' do
      resource = work_with_mods(
        names: [{ name: 'Lee, Wen-Han', roles: ['Creator'] },
                { name: 'Lee, Wen-Han', roles: ['Creator'] },
                { name: '', roles: ['Creator'] }]
      )

      expect(described_class.new(resource: resource).to_solr[:creator_ssim]).to eq(['Lee, Wen-Han'])
    end

    # Subjects moved to MODSIndexer, which writes them for every Modsable
    # resource rather than Works alone. Asserted here so the move is not undone
    # by someone re-adding the field where it used to live.
    it 'leaves the subject field to MODSIndexer' do
      resource = work_with_mods(topical_subjects: ['Civil society'])

      result = described_class.new(resource: resource).to_solr
      expect(result).not_to have_key(:keyword_ssim)
      expect(result).not_to have_key(:subject_ssim)
    end

    it 'omits a field whose source is absent' do
      resource = work_with_mods(names: [{ name: 'Lee, Wen-Han', roles: ['Creator'] }])

      result = described_class.new(resource: resource).to_solr
      expect(result).to have_key(:creator_ssim)
      expect(result).not_to have_key(:pub_date_ssim)
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands the citation fields on the Work doc when the Work is saved' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      doc = citation_fields_in_solr(work)
      # Two creator-role names (one personal, one corporate); the Contributor
      # (Flynn) is excluded.
      expect(doc['creator_ssim'].size).to eq(2)
      expect(doc['creator_ssim'].join).not_to match(/Flynn/)
      expect(doc['pub_date_ssim']).to eq(['2017'])
    end

    it 'has no citation fields on the doc for a Work with no MODS metadata' do
      Atlas.persister.save(resource: Work.find(work.noid))

      doc = citation_fields_in_solr(work)
      expect(doc).not_to have_key('creator_ssim')
      expect(doc).not_to have_key('pub_date_ssim')
    end
  end
end
