# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LazySolrCommit do
  let(:solr) { Atlas.index_adapter.connection }

  # Straight to Solr, around RSolr, so the lookup itself cannot commit.
  def visible_without_commit?(id)
    uri = URI("#{SolrCore.url}/select")
    uri.query = URI.encode_www_form(q: %(id:"#{id}"), wt: 'json')
    JSON.parse(Net::HTTP.get(uri)).dig('response', 'numFound').positive?
  end

  def found?(id)
    solr.get('select', params: { q: %(id:"#{id}") })['response']['numFound'].positive?
  end

  before do
    found?('drain')
    allow(solr).to receive(:soft_commit).and_call_original
  end

  after { Atlas.persister.wipe! }

  it 'leaves a save unsearchable until something reads' do
    work = Atlas.persister.save(resource: Work.new)

    expect(visible_without_commit?(work.id)).to be(false)
  end

  it 'commits before the first read, so the read sees the save' do
    work = Atlas.persister.save(resource: Work.new)

    expect(found?(work.id)).to be(true)
    expect(solr).to have_received(:soft_commit).once
  end

  it 'sends no commit for a read with no write before it' do
    found?('anything')
    found?('anything')

    expect(solr).not_to have_received(:soft_commit)
  end

  it 'commits once however many writes came before the read' do
    works = Array.new(3) { Atlas.persister.save(resource: Work.new) }

    expect(works.map { |work| found?(work.id) }).to all(be(true))
    expect(solr).to have_received(:soft_commit).once
  end

  it 'leaves the adapter itself not committing on save' do
    expect(Atlas.index_adapter.soft_commit?).to be(false)
  end
end
