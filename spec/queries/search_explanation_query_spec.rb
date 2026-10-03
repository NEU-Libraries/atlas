# frozen_string_literal: true

require 'rails_helper'

# What the explanation says, against the test core, which ships the catalog's
# solrconfig.xml and schema.xml.
RSpec.describe SearchExplanationQuery do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # work-mods.xml carries the subjects "Civil society" and "First responders".
  let(:work) do
    w = WorkCreator.call(parent_id: collection.noid)
    Work.find(w.noid).mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read
                                      .sub("What's New", 'Coastal Survey')
    Atlas.persister.save(resource: Work.find(w.noid))
  end

  after { Atlas.persister.wipe! }

  def explain(resource, query)
    described_class.call(noid: resource.noid, query: query)
  end

  def field(result, name)
    result[:fields].find { |entry| entry[:field] == name }
  end

  def matched_words(entry)
    entry[:values].flat_map { |value| value[:tokens] }.select { |token| token[:match] }.pluck(:text)
  end

  it 'matches a plural word in the stemmed title field and not in the plain one' do
    result = explain(work, 'coastal surveys')

    expect(result[:matched]).to be(true)
    expect(matched_words(field(result, 'title_tsim'))).to contain_exactly('coastal')
    stemmed = field(result, 'title_stem_tesim')
    expect(stemmed).to include(stored: false, reason: nil)
    expect(stemmed[:values].pluck(:source)).to eq(['title_tsim'])
    expect(matched_words(stemmed)).to contain_exactly('coastal', 'survey')
    expect(stemmed[:query_tokens]).to eq(typed: %w[coastal surveys], analysed: %w[coastal survey])
  end

  it 'explains a query the object does not match, naming the failed clause' do
    result = explain(work, 'whaling logbook')

    expect(result).to include(matched: false, score: 0.0)
    expect(result[:explanation]['match']).to be(false)
    expect(result[:explanation]['details'].first['description']).to start_with('no match on required clause')
    expect(result[:parsed_query]).to include('title_tsim:whaling')
  end

  it 'reports a subject word under the keywords field, with its source' do
    keywords = field(explain(work, 'responders'), 'descriptive_keywords_tesim')

    hit = keywords[:values].find { |value| value[:tokens].any? { |token| token[:match] } }
    expect(hit).to include(source: 'subject_ssim', text: 'First responders')
  end

  it 'names the catalog filter that hides a featured Collection' do
    featured = CollectionCreator.call(parent_id: community.noid)
    featured.featured = true
    featured = Atlas.persister.save(resource: featured)

    expect(explain(featured, 'anything')[:hidden_by]).to eq(['featured'])
    expect(explain(work, 'anything')[:hidden_by]).to eq([])
  end

  it 'says why a field has no text to analyse' do
    result = explain(work, 'coastal')

    expect(field(result, 'name_variant_teim')).to include(stored: false, values: [], reason: 'not_stored')
    expect(field(result, 'full_text_tesimv')).to include(stored: true, values: [], reason: 'full_text')
  end

  it 'reads the searched fields and their boosts from the handler' do
    handler = explain(work, 'coastal')[:handler]

    expect(handler[:qf]).to include('title_tsim' => 10.0, 'identifier_tesim' => 1.0)
    expect(handler[:pf]).to include('title_tsim' => 20.0)
    expect(handler[:tie]).to be_a(Float)
  end

  it 'caps the values analysed from one source and says so' do
    stub_const('SearchExplanationQuery::VALUE_CAP', 1)
    keywords = field(explain(work, 'responders'), 'descriptive_keywords_tesim')

    expect(keywords[:truncated]).to be(true)
    expect(keywords[:values].count { |value| value[:source] == 'subject_ssim' }).to eq(1)
  end

  it 'marks a field whose analysis failed and still returns the rest' do
    allow_any_instance_of(SolrFieldAnalysis).to receive(:analyse).and_wrap_original do |original, request|
      raise 'analysis down' if request[:fields].include?('title_tsim') && request[:value]

      original.call(request)
    end
    result = explain(work, 'responders')

    expect(field(result, 'title_tsim')).to include(reason: 'analysis_failed', values: [])
    expect(matched_words(field(result, 'descriptive_keywords_tesim'))).to include('responder')
  end
end
