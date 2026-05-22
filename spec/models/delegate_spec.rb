# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Delegate do
  it 'mints a NOID via Resource on construction' do
    expect(Delegate.new.noid).to match(/\A[a-z0-9]+\z/)
  end

  it 'persists via Atlas.persister and round-trips by NOID' do
    saved = Atlas.persister.save(
      resource: Delegate.new(
        use:       Role.thumbnail_image.name,
        uri:       'https://iiif.example/iiif/2/abc/full/!200,200/0/default.jpg',
        mime_type: 'image/jpeg'
      )
    )
    reloaded = Delegate.find(saved.noid)
    expect(reloaded).to be_a(Delegate)
    expect(reloaded.use).to eq(Role.thumbnail_image.name)
    expect(reloaded.uri).to eq('https://iiif.example/iiif/2/abc/full/!200,200/0/default.jpg')
    expect(reloaded.mime_type).to eq('image/jpeg')
  end

  it 'does not carry binary-shaped attributes (no file_identifiers, no size)' do
    expect(Delegate.new).not_to respond_to(:file_identifiers)
    expect(Delegate.new).not_to respond_to(:size)
  end
end
