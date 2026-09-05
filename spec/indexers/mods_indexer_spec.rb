# frozen_string_literal: true

require 'rails_helper'

# Covers the operational-flag half of MODSIndexer plus the match-only title.
# The other MODS projections (description / permanent_url) are exercised through
# the request and decorator specs; the flags are what a search result row reads
# directly, where an unindexed field means the pill cannot render at all.
RSpec.describe MODSIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  def flag_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'in_progress_bsi,incomplete_bsi,incomplete_reason_ssi' }
    ).dig('response', 'docs').first
  end

  # The default keyword search a reader gets from the search box: no defType
  # and no qf, so the request handler's own defaults decide, exactly as they do
  # for a real query. Pass fields: to narrow the qf, which is how the control case
  # below proves a match came from the qf entry and not from somewhere else.
  def keyword_search(query, fields: nil)
    params = { q: query, fl: 'id' }
    params[:qf] = fields if fields
    Atlas.index_adapter.connection.get('select', params: params)
         .dig('response', 'docs').pluck('id')
  end

  def title_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'title_tsim,title_plain_tsim' }
    ).dig('response', 'docs').first
  end

  # A Work whose #mods returns a controlled access copy, so the projection is
  # asserted directly rather than through the WorkCreator template.
  def work_titled(title)
    mods = Metadata::MODS.new(main_title: Metadata::Fields::TitleInfo.new(title: title))
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }
  end

  describe '#to_solr' do
    it 'projects both lifecycle flags on a fresh Work, with a null reason' do
      fields = described_class.new(resource: work).to_solr

      expect(fields[:in_progress_bsi]).to        be true
      expect(fields[:incomplete_bsi]).to         be false
      expect(fields[:incomplete_reason_ssi]).to  be_nil
    end

    it 'projects the reason token once the Work is flagged' do
      work.incomplete        = true
      work.incomplete_reason = 'pdf_rendition_gave_up'

      fields = described_class.new(resource: work).to_solr

      expect(fields[:incomplete_bsi]).to        be true
      expect(fields[:incomplete_reason_ssi]).to eq('pdf_rendition_gave_up')
    end

    it 'omits the pair on resources that do not carry it' do
      expect(described_class.new(resource: Blob.new).to_solr).not_to have_key(:incomplete_bsi)
      expect(described_class.new(resource: FileSet.new).to_solr).not_to have_key(:incomplete_bsi)
    end
  end

  describe 'title_plain_tsim' do
    let(:formula) do
      'Origin of the high-energy kink in the superconductor ' \
        'Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>'
    end

    it 'projects the markup-free title beside the display title' do
      fields = described_class.new(resource: work_titled(formula)).to_solr

      expect(fields[:title_tsim]).to eq(formula)
      expect(fields[:title_plain_tsim])
        .to eq('Origin of the high-energy kink in the superconductor Bi2Sr2CaCu2O8')
    end

    it 'is absent for a title that carries no markup, so titles are not indexed twice' do
      fields = described_class.new(resource: work_titled('Campus Life')).to_solr

      expect(fields[:title_tsim]).to eq('Campus Life')
      expect(fields).not_to have_key(:title_plain_tsim)
    end

    it 'is absent on a resource that holds no title at all' do
      expect(described_class.new(resource: Blob.new).to_solr).not_to have_key(:title_plain_tsim)
    end
  end

  # A field can be projected, stored and displayed and still be absent from
  # Solr, which is a third direction of drift that neither the attr_json
  # derivation nor the display guard catches. `languages` was the proof: read
  # from the record, rendered on the page, and zero values across every indexed
  # document, so a language facet was impossible rather than unconfigured.
  describe 'the descriptive fields discovery needs' do
    def work_from_coverage_fixture
      xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
      mods = Metadata::MODS.new.tap { |m| m.assign_attributes(NEU::MODS::Document.parse(xml).to_h) }
      Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }
    end

    subject(:fields) { described_class.new(resource: work_from_coverage_fixture).to_solr }

    it 'indexes the language, which nothing wrote before' do
      expect(fields[:language_ssim]).to eq(['English'])
    end

    it 'indexes every subject axis under its own field' do
      aggregate_failures do
        expect(fields[:subject_ssim]).to eq(['Interpreting'])
        expect(fields[:subject_geo_ssim]).to contain_exactly('Parksville', 'Boston (Mass.)')
        expect(fields[:subject_era_ssim]).to eq(['21st century'])
        expect(fields[:subject_person_ssim]).to eq(['Smith, John'])
      end
    end

    # bdr_43888.mods.xml uses this axis INSTEAD of subject/geographic, so
    # without the join that record is browsable by no place at all.
    it 'browses a hierarchical place at its narrowest level, in the Places facet' do
      aggregate_failures do
        expect(fields[:subject_geo_ssim]).to include('Parksville')
        expect(fields[:subject_geo_ssim]).not_to include('United States', 'New York')
      end
    end

    it 'indexes the remaining corpus fields discovery needs' do
      aggregate_failures do
        expect(fields[:place_ssim]).to eq(['Boston'])
        expect(fields[:photo_category_ssim]).to eq(['PS3552.E1'])
        expect(fields[:subject_title_tesim]).to eq(['The Great Gatsby'])
        expect(fields[:contents_tesim]).to eq(['Chapter 1 -- Chapter 2'])
      end
    end

    # The fixture's classification is a genuine LC call number, which the
    # migrated corpus does carry, but the field is named for the value DRS
    # writes on every photo ingest: an IPTC category mapped through Cerberus's
    # CATEGORY_LABELS.
    it 'indexes an IPTC photo category under the field named for it' do
      mods = Metadata::MODS.new(classification: ['community outreach'])
      work = Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }

      expect(described_class.new(resource: work).to_solr[:photo_category_ssim])
        .to eq(['community outreach'])
    end

    # A subject genre and a resource genre are the same vocabulary, so they
    # share the facet a reader already browses.
    it 'folds a subject genre into the genre facet' do
      expect(fields[:genre_ssim]).to include('Field recordings')
    end

    it 'indexes the provenance fields' do
      aggregate_failures do
        expect(fields[:publisher_ssim]).to eq(['Northeastern University Press'])
        expect(fields[:series_ssim]).to eq(['A Series'])
        expect(fields[:host_collection_ssim]).to eq(['A Host Collection'])
      end
    end

    it 'indexes every value of a repeatable element, not just the first' do
      expect(fields[:resource_type_ssim]).to eq(['text', 'still image'])
    end

    # Indexed as text so a DOI CAN be matched. Whether it IS depends on the
    # request handler's qf, which the blacklight-solr image owns.
    #
    # The value alone reaches Solr, not the model: a reader pastes the digits,
    # and indexing the type beside them would only add noise to the match.
    it 'indexes identifiers as text, taking the value off the entry' do
      expect(fields[:identifier_tesim]).to eq(['10.17760/D20123456'])
    end

    # A reader searching an alternative title found nothing: the variants were
    # projected and displayed but reachable by no query.
    it 'gathers every title variant into one match-only field' do
      variants = Metadata::MODS.new(
        alternative_title: ['An Alternative Title'],
        uniform_title:     ['A Uniform Title'],
        translated_title:  ['A Translated Title'],
        abbreviated_title: ['An Abbrev. Title']
      )
      resource = Work.new.tap { |w| allow(w).to receive(:mods).and_return(variants) }

      expect(described_class.new(resource: resource).to_solr[:title_variant_tesim])
        .to contain_exactly('An Alternative Title', 'A Uniform Title',
                            'A Translated Title', 'An Abbrev. Title')
    end

    # title_tsim is the heading a result row renders. A variant joining it
    # would change what a reader sees, not just what they can find.
    it 'keeps the variants out of the display title' do
      resource = work_titled('The Real Title')
      allow(resource.mods).to receive(:alternative_title).and_return(['An Alternative Title'])

      result = described_class.new(resource: resource).to_solr
      expect(result[:title_tsim]).to eq('The Real Title')
      expect(result[:title_variant_tesim]).to eq(['An Alternative Title'])
    end

    it 'omits a field whose source is empty, so a sparse record carries no empty facets' do
      sparse = described_class.new(resource: work_titled('Bare')).to_solr

      aggregate_failures do
        MODSIndexer::SOLR_FIELDS.each_value do |solr_field|
          expect(sparse).not_to have_key(solr_field), "#{solr_field} was written for a bare record"
        end
      end
    end

    it 'de-duplicates and drops blank members' do
      mods = Metadata::MODS.new(topical_subjects: ['Civil society', 'Civil society', ''])
      resource = Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }

      expect(described_class.new(resource: resource).to_solr[:subject_ssim]).to eq(['Civil society'])
    end
  end

  # The guard. Without it a field lands in the projection and no one notices it
  # never reached discovery; that is how languages went unindexed for the life
  # of the index.
  describe 'index coverage' do
    it 'accounts for every projected field, as indexed here or as an explicit omission' do
      expect(NEU::MODS::FIELDS.keys - described_class::SOLR_FIELDS.keys - described_class::NOT_INDEXED.keys)
        .to be_empty
    end

    it 'indexes nothing the gem does not project' do
      expect(described_class::SOLR_FIELDS.keys - NEU::MODS::FIELDS.keys).to be_empty
    end

    it 'omits nothing it also indexes' do
      expect(described_class::NOT_INDEXED.keys & described_class::SOLR_FIELDS.keys).to be_empty
    end

    it 'gives a reason for every omission, so the list stays a decision' do
      expect(described_class::NOT_INDEXED.values.select(&:blank?)).to be_empty
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands the flag and its reason on the Work doc' do
      work.incomplete        = true
      work.incomplete_reason = 'media_rendition_gave_up'
      Atlas.persister.save(resource: work)

      doc = flag_fields_in_solr(work)
      expect(doc['incomplete_bsi']).to        be true
      expect(doc['incomplete_reason_ssi']).to eq('media_rendition_gave_up')
    end

    it 'clears both fields from the doc when the Work is repaired' do
      work.incomplete        = true
      work.incomplete_reason = 'ingest_gave_up'
      Atlas.persister.save(resource: work)

      repaired = Work.find(work.noid)
      repaired.incomplete        = false
      repaired.incomplete_reason = nil
      Atlas.persister.save(resource: repaired)

      doc = flag_fields_in_solr(work)
      expect(doc['incomplete_bsi']).to be false
      expect(doc).not_to have_key('incomplete_reason_ssi')
    end

    it 'makes the formula a reader types matchable, while the heading keeps its markup' do
      Work.find(work.noid).mods_xml =
        Rails.root.join('spec/fixtures/files/work-enhanced-text-mods.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      doc = title_fields_in_solr(work)
      expect(doc['title_tsim'].join).to include('Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>')
      expect(doc['title_plain_tsim'].join).to include('Bi2Sr2CaCu2O8')

      # The reader's query. It matched nothing before this field existed,
      # because title_tsim tokenises "sub" and "2" apart from "Bi".
      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'title_plain_tsim:"Bi2Sr2CaCu2O8"', fl: 'id' }
      ).dig('response', 'docs')
      expect(hits.pluck('id')).to eq([work.id.to_s])
    end

    # The indexer spec alone cannot prove a field reaches the collection: it
    # asserts the hash the indexer returns, not what Solr stored. This is the
    # check that would have caught the language gap.
    it 'lands the descriptive fields on the Work doc, where a facet can read them' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      doc = Atlas.index_adapter.connection.get(
        'select',
        params: { q:  %(id:"#{work.id}"),
                  fl: 'language_ssim,subject_ssim,subject_geo_ssim,resource_type_ssim,publisher_ssim' }
      ).dig('response', 'docs').first

      aggregate_failures do
        expect(doc['language_ssim']).to eq(['English'])
        expect(doc['subject_ssim']).to eq(['Interpreting'])
        expect(doc['subject_geo_ssim']).to contain_exactly('Parksville', 'Boston (Mass.)')
        expect(doc['resource_type_ssim']).to contain_exactly('text', 'still image')
        expect(doc['publisher_ssim']).to eq(['Northeastern University Press'])
      end
    end

    # Indexing a text field does not make it searched: the keyword handler only
    # matches what its qf names, and that lives in the blacklight-solr image.
    # These two queries are the only proof that the pair actually works, and
    # they fail if the image drifts from the fields written here.
    it 'answers the query a reader types, for a variant title and a pasted identifier' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      aggregate_failures do
        expect(keyword_search('"An Alternative Title"')).to eq([work.id.to_s])
        expect(keyword_search('"10.17760/D20123456"')).to eq([work.id.to_s])

        # The control. The schema copies every *_tesim field into a catch-all,
        # so without this the two assertions above could pass while qf named
        # neither field. Restricted to the primary title, both find nothing.
        expect(keyword_search('"An Alternative Title"', fields: 'title_tsim')).to be_empty
        expect(keyword_search('"10.17760/D20123456"', fields: 'title_tsim')).to be_empty
      end
    end

    # The corpus pass added these two and they were indexed and unfindable
    # until blacklight-solr named them in the keyword handler's qf.
    it 'answers the query a reader types, for a subject title and a contents list' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      aggregate_failures do
        expect(keyword_search('"The Great Gatsby"')).to eq([work.id.to_s])
        expect(keyword_search('"Chapter 1"')).to eq([work.id.to_s])

        # The control, for the reason the example above carries one: the schema
        # copies every *_tesim field into a catch-all, so both queries could
        # pass while qf named neither field.
        expect(keyword_search('"The Great Gatsby"', fields: 'title_tsim')).to be_empty
        expect(keyword_search('"Chapter 1"', fields: 'title_tsim')).to be_empty
      end
    end

    # A subject title is a work the record is ABOUT. Boosting it would let it
    # compete with the record's own title, which is why it is unboosted in qf.
    it 'ranks a record matched on its own title above one matched on a subject title' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      titled = WorkCreator.call(parent_id: collection.noid)
      Work.find(titled.noid).mods_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
          <mods:titleInfo usage="primary"><mods:title>The Great Gatsby</mods:title></mods:titleInfo>
        </mods:mods>
      XML
      Atlas.persister.save(resource: Work.find(titled.noid))

      expect(keyword_search('"The Great Gatsby"').first).to eq(titled.id.to_s)
    end

    it 'makes the new fields facetable, which is the point of indexing them' do
      Work.find(work.noid).mods_xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      facets = Atlas.index_adapter.connection.get(
        'select',
        params: { q: '*:*', rows: 0, facet: true, 'facet.field' => %w[language_ssim subject_geo_ssim] }
      ).dig('facet_counts', 'facet_fields')

      aggregate_failures do
        expect(facets['language_ssim']).to include('English')
        expect(facets['subject_geo_ssim']).to include('Boston (Mass.)')
      end
    end
  end
end
