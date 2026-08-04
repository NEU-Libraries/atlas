# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SortIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  # Build a Work whose #mods returns a controlled JSON access copy, so the
  # normalisation is asserted directly; the real fixture drives the end-to-end
  # example below.
  def work_with_mods(title: nil, names: [], **dates)
    mods = Metadata::MODS.new(
      main_title: title && Metadata::Fields::TitleInfo.new(**title),
      names:      names.map { |attrs| Metadata::Fields::Name.new(**attrs) },
      **dates
    )
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }
  end

  def sort_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'title_ssi,creator_ssi,date_ssi' }
    ).dig('response', 'docs').first
  end

  def title_key(**parts)
    described_class.new(resource: work_with_mods(title: parts)).to_solr[:title_ssi]
  end

  describe 'title_ssi' do
    it 'folds case and drops punctuation' do
      expect(title_key(title: 'Campus Life: A Photographic Record!')).to eq('campus life a photographic record')
    end

    it 'drops the nonSort prefix the record marked as not for sorting' do
      expect(title_key(title: 'Hobbit', non_sort: 'The ')).to eq('hobbit')
    end

    it 'drops a leading article the record put in the title itself' do
      expect(title_key(title: 'The Hobbit')).to eq('hobbit')
      expect(title_key(title: 'An Oral History')).to eq('oral history')
      expect(title_key(title: 'A Register of Deeds')).to eq('register of deeds')
    end

    it 'keeps an article that is not leading' do
      expect(title_key(title: 'Songs of a Sourdough')).to eq('songs of a sourdough')
    end

    it 'left-pads numbers so they order numerically' do
      expect(title_key(title: 'Chapter 2')).to eq('chapter 000002')
      expect(title_key(title: 'Chapter 10')).to eq('chapter 000010')
      expect(title_key(title: 'Chapter 2')).to be < title_key(title: 'Chapter 10')
    end

    it 'leaves a number longer than the pad width unpadded' do
      expect(title_key(title: 'Box 1234567')).to eq('box 1234567')
    end

    it 'sorts on the composed title, subtitle and part included' do
      expect(title_key(title: 'Report', subtitle: 'Second Series', part_number: '3'))
        .to eq('report second series 000003')
    end

    it 'collapses the whitespace that punctuation removal leaves behind' do
      expect(title_key(title: 'Boston -- A History')).to eq('boston a history')
    end

    it 'is absent when the resource has no title' do
      expect(described_class.new(resource: work_with_mods).to_solr).not_to have_key(:title_ssi)
    end

    it 'sorts a resource that holds no MODS by its display name' do
      person = Person.new(display_name: 'Doe, Jane', title: 'Professor of Marine Sciences')

      expect(described_class.new(resource: person).to_solr[:title_ssi]).to eq('doe jane')
    end
  end

  describe 'creator_ssi' do
    it 'projects the first creator-role name, case-folded' do
      resource = work_with_mods(names: [{ name: 'Smith, Editor', role: 'Contributor' },
                                        { name: 'Lee, Wen-Han', role: 'Creator' },
                                        { name: 'Flynn, Second', role: 'creator' }])

      expect(described_class.new(resource: resource).to_solr[:creator_ssi]).to eq('lee, wen-han')
    end

    it 'falls back to the first name of any role when no name declares creator' do
      resource = work_with_mods(names: [{ name: 'Smith, Editor', role: 'Contributor' }])

      expect(described_class.new(resource: resource).to_solr[:creator_ssi]).to eq('smith, editor')
    end

    it 'is absent when the resource has no names' do
      expect(described_class.new(resource: work_with_mods).to_solr).not_to have_key(:creator_ssi)
    end
  end

  describe 'date_ssi' do
    it 'projects the date of creation as a full UTC instant' do
      resource = work_with_mods(date_created: Time.zone.parse('1923-05-01'))

      expect(described_class.new(resource: resource).to_solr[:date_ssi]).to eq('1923-05-01T00:00:00Z')
    end

    it 'falls back to the copyright date, then to the date of issue' do
      copyright = work_with_mods(copyright_date: Time.zone.parse('1955-01-01'),
                                 date_issued:    Time.zone.parse('1960-01-01'))
      issued    = work_with_mods(date_issued: Time.zone.parse('1960-01-01'))

      expect(described_class.new(resource: copyright).to_solr[:date_ssi]).to eq('1955-01-01T00:00:00Z')
      expect(described_class.new(resource: issued).to_solr[:date_ssi]).to eq('1960-01-01T00:00:00Z')
    end

    it 'is absent when the resource carries no origin date' do
      expect(described_class.new(resource: work_with_mods).to_solr).not_to have_key(:date_ssi)
    end

    it 'is a different sort from created_at, the date the repository made the record' do
      resource = work_with_mods(date_created: Time.zone.parse('1923-05-01'))

      expect(described_class.new(resource: resource).to_solr[:date_ssi])
        .not_to eq(Time.current.utc.strftime('%Y-%m-%dT%H:%M:%SZ'))
    end
  end

  describe '#to_solr' do
    it 'returns an empty hash for a resource that holds no descriptive metadata' do
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
      expect(described_class.new(resource: Work.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands all three fields on a Work doc, single-valued and sortable' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      doc = sort_fields_in_solr(work)
      # Each field comes back as a scalar, not an array — a multi-valued field
      # is what Solr refuses to sort on.
      expect(doc['title_ssi']).to eq('whats new how we respond to disaster episode 000001')
      expect(doc['creator_ssi']).to start_with('cohen') # the first creator-role name, not the Contributor
      expect(doc['date_ssi']).to eq('2017-09-19T00:00:00Z')
    end

    it 'lands a sortable title on a Collection doc, so a mixed result list orders' do
      Collection.find(collection.noid).mods_xml =
        Rails.root.join('spec/fixtures/files/collection-mods.xml').read
      Atlas.persister.save(resource: Collection.find(collection.noid))

      expect(sort_fields_in_solr(collection)['title_ssi']).to eq('test collection')
    end

    it 'sorts a Person under their name, not under the job title they carry' do
      person = PersonCreator.call(nuid: '001234567', display_name: 'Doe, Jane',
                                  title: 'Professor of Marine and Environmental Sciences')

      # Valkyrie projects the `title` attribute into every title_* suffix,
      # title_ssi included, so the indexer's value has to win — as PersonIndexer's
      # title_tsim already does. Otherwise a Person sorts under their job title:
      # unnormalised, so ahead of every real sort title, and keyed on a value the
      # row never shows.
      expect(sort_fields_in_solr(person)['title_ssi']).to eq('doe jane')
    end

    it 'answers a real Solr sort on title_ssi, a Person in the result set' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))
      PersonCreator.call(nuid: '001234567', display_name: 'Doe, Jane',
                         title: 'Professor of Marine and Environmental Sciences')

      docs = Atlas.index_adapter.connection.get(
        'select', params: { q: 'title_ssi:[* TO *]', sort: 'title_ssi asc', fl: 'title_ssi' }
      ).dig('response', 'docs')

      keys = docs.pluck('title_ssi')
      expect(keys).to be_present
      expect(keys).to eq(keys.sort)
      expect(keys).to include('doe jane')
      expect(keys.join(' ')).not_to match(/professor/i)
    end
  end
end
