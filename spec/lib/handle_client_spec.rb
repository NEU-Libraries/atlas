# frozen_string_literal: true

require 'rails_helper'

# Atlas has no HTTP-stubbing gem, and this is its only outbound client, so the
# transport is stubbed at Net::HTTP itself. `sent` collects the request objects
# the client builds, which is what most of these examples are really about.
RSpec.describe HandleClient do
  subject(:client) do
    described_class.new(server_url: 'https://handle:8000', prefix: 'DRSDEV',
                        admin_secret: 'sekrit', verify_ssl: false)
  end

  let(:http) { instance_double(Net::HTTP, :open_timeout= => nil, :read_timeout= => nil) }
  let(:sent) { [] }

  # A Net::HTTPResponse is awkward to build by hand; the client reads only
  # these three things off it.
  def response_double(body, success: true, code: '200')
    instance_double(Net::HTTPOK, code: code, body: body.is_a?(String) ? body : body.to_json).tap do |double|
      allow(double).to receive(:is_a?).with(Net::HTTPSuccess).and_return(success)
    end
  end

  def mint(suffix = 'neu:abc123')
    client.mint(suffix, url: "https://example.edu/works/#{suffix}")
  end

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:verify_mode=)
    allow(http).to receive(:request) do |request|
      sent << request
      response_double({ 'responseCode' => 1 })
    end
  end

  describe '#configured?' do
    it 'is true when the server, prefix and secret are all present' do
      expect(client).to be_configured
    end

    it 'is false when any one of them is missing' do
      expect(described_class.new(server_url: 'https://handle:8000', prefix: 'DRSDEV', admin_secret: nil))
        .not_to be_configured
    end

    it 'treats a blank value as absent' do
      expect(described_class.new(server_url: '', prefix: 'DRSDEV', admin_secret: 'sekrit'))
        .not_to be_configured
    end
  end

  describe '#mint' do
    it 'returns the full "<prefix>/<suffix>" handle' do
      expect(mint).to eq('DRSDEV/neu:abc123')
    end

    it 'PUTs to the handle path with the prefix slash unescaped' do
      mint

      expect(sent.last).to be_a(Net::HTTP::Put)
      expect(sent.last.path).to eq('/api/handles/DRSDEV/neu:abc123')
    end

    it 'sends the URL as value index 1' do
      mint

      expect(JSON.parse(sent.last.body)['values']).to eq(
        [{ 'index' => 1, 'type' => 'URL',
           'data' => { 'format' => 'string', 'value' => 'https://example.edu/works/neu:abc123' } }]
      )
    end

    # The colon between admin index and admin handle is percent-encoded, so
    # Basic auth cannot mistake it for its own separator.
    it 'authenticates as the admin handle with a percent-encoded index colon' do
      mint

      credential = Base64.decode64(sent.last['Authorization'].sub('Basic ', ''))
      expect(credential).to eq('300%3ADRSDEV/ADMIN:sekrit')
    end

    it 'turns TLS verification off when asked to' do
      mint

      expect(http).to have_received(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)
    end

    it 'verifies TLS by default' do
      described_class.new(server_url: 'https://handle:8000', prefix: 'DRSDEV', admin_secret: 'sekrit')
                     .mint('neu:abc123', url: 'https://example.edu/works/neu:abc123')

      expect(http).to have_received(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
    end
  end

  describe 'failure handling' do
    # Nothing in front of the handle server speaks Handle, so a reply with no
    # responseCode (a proxy error, say) is judged on its HTTP status alone.
    it 'raises Error on a non-success HTTP status carrying no Handle code' do
      allow(http).to receive(:request)
        .and_return(response_double({ 'error' => 'bad gateway' }, success: false, code: '502'))

      expect { mint }.to raise_error(described_class::Error, /HTTP 502/)
    end

    # The server mirrors a refused credential into a 401, so the Handle code
    # is what the message must name.
    it 'raises Error on a Handle responseCode that is not success' do
      allow(http).to receive(:request)
        .and_return(response_double({ 'responseCode' => 402 }, success: false, code: '401'))

      expect { mint }.to raise_error(described_class::Error, /responseCode 402/)
    end

    # A refused connection must reach the caller as the one error type it
    # rescues, not as a bare Errno.
    it 'wraps a transport failure as Error' do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect { mint }.to raise_error(described_class::Error, /unreachable/)
    end

    it 'wraps a timeout as Error' do
      allow(http).to receive(:request).and_raise(Net::OpenTimeout)

      expect { mint }.to raise_error(described_class::Error, /unreachable/)
    end

    it 'raises Error on an unparseable body' do
      allow(http).to receive(:request).and_return(response_double('<html>nope</html>'))

      expect { mint }.to raise_error(described_class::Error, /unparseable/)
    end

    # A refused credential is a bare 401 with no body, which must read as the
    # status it is rather than as a parse failure.
    it 'reports the status when a rejected request carries no body' do
      allow(http).to receive(:request).and_return(response_double('', success: false, code: '401'))

      expect { mint }.to raise_error(described_class::Error, /HTTP 401/)
    end
  end

  describe '#resolve' do
    it 'returns the URL value of an existing handle' do
      values = [{ 'type' => 'URL', 'data' => { 'value' => 'https://example.edu/works/x' } }]
      allow(http).to receive(:request)
        .and_return(response_double({ 'responseCode' => 1, 'values' => values }))

      expect(client.resolve('DRSDEV/x')).to eq('https://example.edu/works/x')
    end

    # 100 is Handle's "no such handle" — an answer, not a failure. The server
    # mirrors it into a 404, so the HTTP status must not be read as the
    # failure it looks like. Verified against the real server, which is the
    # only way this shape came to light.
    it 'returns nil when the server has no such handle, despite the 404' do
      allow(http).to receive(:request)
        .and_return(response_double({ 'responseCode' => 100 }, success: false, code: '404'))

      expect(client.resolve('DRSDEV/missing')).to be_nil
    end
  end
end
