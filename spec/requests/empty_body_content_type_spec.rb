# frozen_string_literal: true

require 'rails_helper'

# A bare 404 or 416 must not claim a JSON body it does not have, or a client
# that parses by Content-Type throws on it. lib/empty_body_content_type.rb.
RSpec.describe 'A response with no body', type: :request do
  it 'names no media type on a bare 404' do
    get '/works/nosuchnoid'

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
    expect(response.headers['Content-Type']).to be_nil
  end

  it 'keeps the media type on a response with a body' do
    get '/health'

    expect(response.headers['Content-Type']).to start_with('application/json')
  end
end
