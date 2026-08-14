# frozen_string_literal: true

require 'rails_helper'

# /oai is a protocol endpoint, not an API operation, so this is a plain
# request spec rather than an rswag one — the same reasoning that keeps
# spec/requests/docs_spec.rb out of openapi/openapi.yaml. Every response is
# validated against the real OAI-PMH, oai_dc, oai-identifier and MODS schemas
# (see OAISchemaHelper), which is a far stronger check than shape assertions.
#
# Fixture repository:
#
#   community (public)
#   └─ collection (public)
#       ├─ work_one       public, complete            harvestable
#       ├─ work_two       public, complete            harvestable
#       ├─ work_three     public, complete            harvestable
#       ├─ deleted_work   public, complete, tombstoned  header status="deleted"
#       ├─ flagged_work   public, complete, incomplete  harvestable (flags, never hides)
#       ├─ private_work   no public read group        absent
#       └─ pending_work   in_progress                 absent
RSpec.describe 'OAI-PMH provider' do
  include ActiveSupport::Testing::TimeHelpers

  # Transactional fixtures roll Postgres back between examples but leave Solr
  # alone, so documents from earlier examples — here and in every other file —
  # would show up in an unscoped ListIdentifiers and make the counts below
  # meaningless. The provider reads Solr and nothing else, so the index is
  # what has to be clean. Declared before the fixtures so it runs first.
  before { Atlas.index_adapter.persister.wipe! }

  let(:jan) { Time.utc(2026, 1, 10, 12, 0, 0) }
  let(:feb) { Time.utc(2026, 2, 10, 12, 0, 0) }
  let(:mar) { Time.utc(2026, 3, 10, 12, 0, 0) }

  # travel_to fixes the Postgres updated_at each Work is stamped with, which
  # is what OAIIndexer projects as oai_datestamp_dtsi. Without it every
  # fixture lands in the same second and the from/until examples cannot tell
  # them apart.
  def public_work!(at:, **attrs)
    travel_to(at) do
      Atlas.persister.save(
        resource: Work.new(a_member_of: collection.id, read_groups: ['public'],
                           in_progress: false, **attrs)
      )
    end
  end

  let!(:community)  { Atlas.persister.save(resource: Community.new(read_groups: ['public'])) }
  let!(:collection) do
    Atlas.persister.save(resource: Collection.new(a_member_of: community.id, read_groups: ['public']))
  end

  let!(:work_one)   { public_work!(at: jan) }
  let!(:work_two)   { public_work!(at: feb) }
  let!(:work_three) { public_work!(at: mar) }

  let(:noids) { [work_one.noid, work_two.noid, work_three.noid] }

  def get_oai(args)
    get '/oai', params: args
    expect_valid_oai(response.body)
    oai_doc(response.body)
  end

  def error_code(args)
    get_oai(args).at_xpath('//error')&.[]('code')
  end

  def identifiers(doc)
    doc.xpath('//header/identifier').map(&:text)
  end

  describe 'transport' do
    it 'answers GET' do
      get '/oai', params: { verb: 'Identify' }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/xml')
    end

    # The protocol requires a repository to accept both methods at one baseURL.
    it 'answers POST with a form-encoded body' do
      post '/oai', params: { verb: 'Identify' }

      expect(response).to have_http_status(:ok)
      expect(oai_doc(response.body).at_xpath('//Identify')).to be_present
    end

    # No principal is involved at all: the feed sees the literal `public`
    # group and nothing a caller could send would widen it.
    it 'needs no authentication' do
      get '/oai', params: { verb: 'ListIdentifiers', metadataPrefix: 'mods' }, headers: {}

      expect(identifiers(oai_doc(response.body))).to match_array(noids.map { |n| OAI.identifier_for(n) })
    end
  end

  describe 'Identify' do
    it 'advertises the endpoint, not the site root' do
      doc = get_oai(verb: 'Identify')

      expect(doc.at_xpath('//baseURL').text).to eq(OAI.config.base_url)
      expect(doc.at_xpath('//request').text).to eq(OAI.config.base_url)
    end

    it 'advertises a repositoryIdentifier and a well-formed sampleIdentifier' do
      doc = get_oai(verb: 'Identify')

      expect(doc.at_xpath('//repositoryIdentifier').text).to eq('repository.library.northeastern.edu')
      expect(doc.at_xpath('//sampleIdentifier').text).to start_with('oai:repository.library.northeastern.edu:')
    end

    it 'reports the oldest record as earliestDatestamp' do
      doc = get_oai(verb: 'Identify')

      expect(doc.at_xpath('//earliestDatestamp').text).to eq(jan.iso8601)
      expect(doc.at_xpath('//deletedRecord').text).to eq('transient')
      expect(doc.at_xpath('//granularity').text).to eq('YYYY-MM-DDThh:mm:ssZ')
    end
  end

  describe 'ListMetadataFormats' do
    it 'lists both formats' do
      doc = get_oai(verb: 'ListMetadataFormats')

      expect(doc.xpath('//metadataPrefix').map(&:text)).to contain_exactly('oai_dc', 'mods')
    end

    it 'accepts an identifier' do
      doc = get_oai(verb: 'ListMetadataFormats', identifier: OAI.identifier_for(work_one.noid))

      expect(doc.xpath('//metadataPrefix').map(&:text)).to contain_exactly('oai_dc', 'mods')
    end
  end

  describe 'ListIdentifiers' do
    it 'lists every harvestable Work' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')

      expect(identifiers(doc)).to match_array(noids.map { |n| OAI.identifier_for(n) })
    end

    it 'orders by datestamp' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')

      expect(doc.xpath('//header/datestamp').map(&:text))
        .to eq([jan, feb, mar].map(&:iso8601))
    end

    it 'omits a Work with no public read group' do
      private_work = travel_to(feb) do
        Atlas.persister.save(resource: Work.new(a_member_of: collection.id, in_progress: false))
      end

      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      expect(identifiers(doc)).not_to include(OAI.identifier_for(private_work.noid))
    end

    it 'omits a Work still in progress' do
      pending_work = public_work!(at: feb, in_progress: true)

      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      expect(identifiers(doc)).not_to include(OAI.identifier_for(pending_work.noid))
    end

    # Work#incomplete flags a degraded record without hiding it. Filtering on
    # it would make records vanish from Digital Commonwealth after a pipeline
    # failure.
    it 'keeps an incomplete Work' do
      flagged = public_work!(at: feb, incomplete: true, incomplete_reason: 'pdf_rendition_gave_up')

      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      expect(identifiers(doc)).to include(OAI.identifier_for(flagged.noid))
    end
  end

  describe 'datestamp filtering' do
    # Assert counts, not just a 200: a nil or ignored bound produces a full,
    # passing-looking list.
    it 'honours from' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods', from: feb.iso8601)

      expect(identifiers(doc)).to contain_exactly(OAI.identifier_for(work_two.noid),
                                                  OAI.identifier_for(work_three.noid))
    end

    it 'honours until' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods', until: feb.iso8601)

      expect(identifiers(doc)).to contain_exactly(OAI.identifier_for(work_one.noid),
                                                  OAI.identifier_for(work_two.noid))
    end

    it 'honours both bounds together' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods',
                    from: feb.iso8601, until: feb.iso8601)

      expect(identifiers(doc)).to contain_exactly(OAI.identifier_for(work_two.noid))
    end

    # A day-level until covers the whole of that day, so a record stamped at
    # noon is inside `until=<that day>`.
    it 'treats a day-granularity until as the whole day' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods', until: '2026-02-10')

      expect(identifiers(doc)).to contain_exactly(OAI.identifier_for(work_one.noid),
                                                  OAI.identifier_for(work_two.noid))
    end

    it 'answers noRecordsMatch for a range holding nothing' do
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods',
                        from: '2030-01-01', until: '2030-12-31')).to eq('noRecordsMatch')
    end
  end

  describe 'ListRecords' do
    it 'carries the preservation MODS verbatim' do
      doc = get_oai(verb: 'ListRecords', metadataPrefix: 'mods')

      expect(doc.xpath('//record').length).to eq(3)
      expect(doc.xpath('//record/metadata/mods').length).to eq(3)
    end

    # The crosswalk reads the JSON access copy, which only exists once a Work
    # has its descriptive-metadata FileSet — so this one goes through
    # WorkCreator rather than a bare Work.new.
    it 'carries an oai_dc crosswalk' do
      described = WorkCreator.call(parent_id: collection.noid)
      set_mods_primary_title!(described, 'A harvestable thing')
      described = Work.find(described.noid)
      described.publicize
      described.in_progress = false
      Atlas.persister.save(resource: described)

      doc = get_oai(verb: 'ListRecords', metadataPrefix: 'oai_dc')

      expect(doc.xpath('//record/metadata/dc/title').map(&:text)).to include('A harvestable thing')
    end

    # v1 never emitted this: a withdrawn item stayed in Digital Commonwealth
    # for good.
    it 'reports a withdrawn Work as deleted, with no metadata' do
      deleted = public_work!(at: feb)
      deleted.tombstone(by: '000000004')
      Atlas.persister.save(resource: deleted)

      doc    = get_oai(verb: 'ListRecords', metadataPrefix: 'mods')
      header = doc.xpath('//header').find { |h| h.at_xpath('identifier').text.end_with?(deleted.noid) }

      expect(header['status']).to eq('deleted')
      expect(header.parent.at_xpath('metadata')).to be_nil
    end
  end

  describe 'GetRecord' do
    it 'returns one record' do
      doc = get_oai(verb: 'GetRecord', metadataPrefix: 'mods',
                    identifier: OAI.identifier_for(work_one.noid))

      expect(doc.xpath('//record').length).to eq(1)
      expect(doc.at_xpath('//header/identifier').text).to eq(OAI.identifier_for(work_one.noid))
    end
  end

  describe 'sets' do
    let(:compilation) do
      Compilation.create!(title: 'Digital Commonwealth', depositor: '000000004', published: true)
    end

    it 'lists published Compilations' do
      compilation
      doc = get_oai(verb: 'ListSets')

      expect(doc.at_xpath('//set/setSpec').text).to eq(compilation.noid)
      expect(doc.at_xpath('//set/setName').text).to eq('Digital Commonwealth')
    end

    # descriptionType requires exactly one foreign-namespace child, so an empty
    # element is schema-invalid — the defect v1's ListSets shipped. The XSD
    # check in get_oai is what enforces this.
    it 'omits setDescription when the Set has none' do
      compilation
      doc = get_oai(verb: 'ListSets')

      expect(doc.at_xpath('//set/setDescription')).to be_nil
    end

    it 'wraps a present description in oai_dc' do
      compilation.update!(description: 'The BPL feed')
      doc = get_oai(verb: 'ListSets')

      expect(doc.at_xpath('//set/setDescription/dc/description').text).to eq('The BPL feed')
    end

    it 'does not advertise an unpublished Compilation' do
      Compilation.create!(title: 'Private', depositor: '000000004')

      expect(error_code(verb: 'ListSets')).to eq('noSetHierarchy')
    end

    it 'narrows a list to the set members' do
      compilation.work_inclusions.create!(resource_noid: work_two.noid)

      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods', set: compilation.noid)
      expect(identifiers(doc)).to contain_exactly(OAI.identifier_for(work_two.noid))
    end

    it 'honours the recipe exclusions' do
      compilation.collection_inclusions.create!(resource_noid: collection.noid)
      compilation.exclusions.create!(resource_noid: work_two.noid)

      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods', set: compilation.noid)
      expect(identifiers(doc)).to contain_exactly(OAI.identifier_for(work_one.noid),
                                                  OAI.identifier_for(work_three.noid))
    end

    it 'stamps every record header with the sets it belongs to' do
      compilation.work_inclusions.create!(resource_noid: work_two.noid)

      doc    = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      header = doc.xpath('//header').find { |h| h.at_xpath('identifier').text.end_with?(work_two.noid) }

      expect(header.xpath('setSpec').map(&:text)).to eq([compilation.noid])
    end

    it 'answers noRecordsMatch for an unknown set' do
      compilation
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods', set: 'nosuchset'))
        .to eq('noRecordsMatch')
    end
  end

  describe 'resumption' do
    # One record per page, so the three works make a three-part list.
    def paginate_one_at_a_time!
      config = OAI.config.dup
      config.records_per_page     = 1
      config.identifiers_per_page = 1
      allow(OAI).to receive(:config).and_return(config)
    end

    it 'walks the whole list and ends on an empty token' do
      paginate_one_at_a_time!
      seen  = []
      doc   = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      seen += identifiers(doc)
      token = doc.at_xpath('//resumptionToken')

      expect(token['completeListSize']).to eq('3')
      expect(token['cursor']).to eq('0')

      until token.text.blank?
        doc    = get_oai(verb: 'ListIdentifiers', resumptionToken: token.text)
        seen  += identifiers(doc)
        token  = doc.at_xpath('//resumptionToken')
      end

      expect(seen).to eq(noids.map { |n| OAI.identifier_for(n) })
      expect(token.text).to eq('')
    end

    it 'carries the metadataPrefix through the token' do
      paginate_one_at_a_time!
      doc   = get_oai(verb: 'ListRecords', metadataPrefix: 'mods')
      token = doc.at_xpath('//resumptionToken').text

      doc = get_oai(verb: 'ListRecords', resumptionToken: token)
      expect(doc.at_xpath('//record/metadata/mods')).to be_present
    end

    # A list that was never partitioned owes no token at all — an empty one
    # would say "you have reached the last part" of a list with no parts.
    it 'emits no token when one response holds the whole list' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')

      expect(doc.at_xpath('//resumptionToken')).to be_nil
    end
  end

  describe 'errors' do
    it 'badVerb for a missing verb' do
      expect(error_code({})).to eq('badVerb')
    end

    it 'badVerb for an unknown verb' do
      expect(error_code(verb: 'Harvest')).to eq('badVerb')
    end

    # The protocol forbids attributes on <request> after badVerb / badArgument:
    # the repository could not make sense of what it was sent.
    it 'echoes no request attributes on badVerb' do
      doc = get_oai(verb: 'Harvest', metadataPrefix: 'mods')

      expect(doc.at_xpath('//request').attributes).to be_empty
    end

    it 'echoes the arguments on every other response' do
      doc = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')

      expect(doc.at_xpath('//request')['verb']).to eq('ListIdentifiers')
      expect(doc.at_xpath('//request')['metadataPrefix']).to eq('mods')
    end

    it 'badArgument for a missing required argument' do
      expect(error_code(verb: 'ListRecords')).to eq('badArgument')
    end

    it 'badArgument for an argument the verb does not accept' do
      expect(error_code(verb: 'Identify', metadataPrefix: 'mods')).to eq('badArgument')
    end

    it 'badArgument for a repeated argument' do
      get '/oai?verb=ListRecords&metadataPrefix=mods&metadataPrefix=oai_dc'

      expect(oai_doc(response.body).at_xpath('//error')['code']).to eq('badArgument')
    end

    it 'badArgument for mismatched date granularity' do
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods',
                        from: '2026-01-01', until: '2026-02-01T00:00:00Z')).to eq('badArgument')
    end

    it 'badArgument when from is later than until' do
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods',
                        from: '2026-03-01', until: '2026-01-01')).to eq('badArgument')
    end

    it 'badArgument for a malformed date' do
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods', from: 'yesterday'))
        .to eq('badArgument')
    end

    # Right shape, no such day. A pattern check alone lets this through, and
    # Time.parse then rolls it forward to 3 March and answers a nonsense
    # request with a plausible list.
    it 'badArgument for a date that does not exist' do
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods', from: '2026-02-31'))
        .to eq('badArgument')
    end

    it 'badArgument for an out-of-range clock time' do
      expect(error_code(verb: 'ListIdentifiers', metadataPrefix: 'mods', from: '2026-02-10T25:00:00Z'))
        .to eq('badArgument')
    end

    # A resumptionToken already fixes the other arguments, so sending them
    # alongside it is an error rather than a silent override.
    it 'badArgument when a resumptionToken is combined with another argument' do
      doc   = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      token = OAI::ResumptionToken.encode({ 'metadataPrefix' => 'mods', 'cursorMark' => '*' })

      expect(error_code(verb: 'ListIdentifiers', resumptionToken: token, metadataPrefix: 'mods'))
        .to eq('badArgument')
      expect(doc).to be_present
    end

    it 'cannotDisseminateFormat for an unsupported prefix' do
      expect(error_code(verb: 'ListRecords', metadataPrefix: 'marc21'))
        .to eq('cannotDisseminateFormat')
    end

    it 'idDoesNotExist for an identifier from another repository' do
      expect(error_code(verb: 'GetRecord', metadataPrefix: 'mods',
                        identifier: 'oai:example.org:abc')).to eq('idDoesNotExist')
    end

    it 'idDoesNotExist for a Work that is not harvestable' do
      private_work = Atlas.persister.save(resource: Work.new(a_member_of: collection.id, in_progress: false))

      expect(error_code(verb: 'GetRecord', metadataPrefix: 'mods',
                        identifier: OAI.identifier_for(private_work.noid))).to eq('idDoesNotExist')
    end

    it 'noMetadataFormats for a withdrawn record' do
      deleted = public_work!(at: feb)
      deleted.tombstone(by: '000000004')
      Atlas.persister.save(resource: deleted)

      expect(error_code(verb:       'ListMetadataFormats',
                        identifier: OAI.identifier_for(deleted.noid))).to eq('noMetadataFormats')
    end

    # A forged or corrupted token must never reach Solr: it carries a
    # cursorMark and a set noid that flow straight into a query.
    it 'badResumptionToken for a forged token' do
      forged = Base64.urlsafe_encode64('{"cursorMark":"*"}', padding: false)

      expect(error_code(verb: 'ListIdentifiers', resumptionToken: "#{forged}.deadbeef"))
        .to eq('badResumptionToken')
    end

    it 'badResumptionToken for a tampered payload' do
      doc   = get_oai(verb: 'ListIdentifiers', metadataPrefix: 'mods')
      valid = OAI::ResumptionToken.encode({ 'metadataPrefix' => 'mods', 'cursorMark' => '*' })
      body, sig = valid.split('.')
      tampered  = Base64.urlsafe_encode64('{"set":"evil","cursorMark":"*"}', padding: false)

      expect(error_code(verb: 'ListIdentifiers', resumptionToken: "#{tampered}.#{sig}"))
        .to eq('badResumptionToken')
      expect([doc, body]).to all(be_present)
    end

    it 'badResumptionToken for a token on ListSets' do
      Compilation.create!(title: 'Feed', depositor: '000000004', published: true)
      token = OAI::ResumptionToken.encode({ 'cursorMark' => '*' })

      expect(error_code(verb: 'ListSets', resumptionToken: token)).to eq('badResumptionToken')
    end
  end
end
