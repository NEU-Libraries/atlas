# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PreviewImageFacts do
  let(:uri)         { 'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg' }
  let(:placeholder) { Base64.strict_encode64("\xFF\xD8\xFF\xE0tiny".b) }

  def facts(body)
    described_class.from(ActionController::Parameters.new(body))
  end

  def rejection(body)
    facts(body)
  rescue Exceptions::PreviewImageError => e
    e.code
  end

  it 'reads the size and placeholder sent with the preview' do
    expect(facts(preview: uri, preview_width: 500, preview_height: 375, preview_placeholder: placeholder))
      .to eq(width: 500, height: 375, placeholder: placeholder)
  end

  it 'reads a dimension sent as a digit string, as a form body sends it' do
    expect(facts(preview: uri, preview_width: '500', preview_height: '375')).to include(width: 500, height: 375)
  end

  # Every key is returned, so a preview written without them clears the old ones.
  it 'answers nil for each fact a preview arrives without' do
    expect(facts(preview: uri)).to eq(width: nil, height: nil, placeholder: nil)
  end

  it 'answers nil for each fact when no preview is sent' do
    expect(facts(thumbnail: 'https://iiif.example/85.jpg')).to eq(width: nil, height: nil, placeholder: nil)
  end

  it 'treats a blank value as absent' do
    expect(facts(preview: uri, preview_width: '', preview_height: '', preview_placeholder: ''))
      .to eq(width: nil, height: nil, placeholder: nil)
  end

  it 'refuses a fact sent without the preview it describes' do
    expect(rejection(preview_width: 500, preview_height: 375)).to eq(:preview_required)
    expect(rejection(preview_placeholder: placeholder)).to eq(:preview_required)
  end

  it 'refuses a width without a height, and the reverse' do
    expect(rejection(preview: uri, preview_width: 500)).to eq(:preview_dimensions_incomplete)
    expect(rejection(preview: uri, preview_height: 375)).to eq(:preview_dimensions_incomplete)
  end

  it 'refuses a dimension that is not a positive integer' do
    [0, -1, 1.5, '12px', 'abc', true].each do |bad|
      expect(rejection(preview: uri, preview_width: bad, preview_height: 375)).to eq(:invalid_preview_dimension)
    end
  end

  it 'refuses a placeholder that is not strict base64' do
    expect(rejection(preview: uri, preview_placeholder: "#{placeholder}\n")).to eq(:invalid_preview_placeholder)
    expect(rejection(preview: uri, preview_placeholder: 'not base64!')).to eq(:invalid_preview_placeholder)
  end

  it 'refuses a placeholder whose bytes are not a JPEG' do
    png = Base64.strict_encode64("\x89PNG\r\n\x1A\n".b)
    expect(rejection(preview: uri, preview_placeholder: png)).to eq(:invalid_preview_placeholder)
  end

  it 'refuses a placeholder over the limit, so the field cannot hold a real image' do
    big = Base64.strict_encode64("\xFF\xD8\xFF".b + ('x' * described_class::PLACEHOLDER_LIMIT))
    expect(rejection(preview: uri, preview_placeholder: big)).to eq(:invalid_preview_placeholder)
  end
end
