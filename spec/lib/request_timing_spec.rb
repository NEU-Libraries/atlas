# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RequestTiming do
  let(:route) { { controller: 'works', action: 'show' } }
  let(:env) { { 'action_dispatch.request.path_parameters' => route } }

  before { allow(RequestLatency).to receive(:record_request) }

  def app_returning(status, delay: 0)
    lambda do |_env|
      sleep(delay)
      [status, {}, ['body']]
    end
  end

  it 'records the time the whole stack below it took, with the route and status' do
    response = described_class.new(app_returning(200, delay: 0.05)).call(env)

    expect(response.first).to eq(200)
    expect(RequestLatency).to have_received(:record_request)
      .with(a_value_between(50, 1000), route: route, status: 200)
  end

  it 'records a raised exception as a 500 and lets it propagate' do
    failing = ->(_env) { raise 'boom' }

    expect { described_class.new(failing).call(env) }.to raise_error(RuntimeError, 'boom')
    expect(RequestLatency).to have_received(:record_request).with(anything, route: route, status: 500)
  end

  it 'never fails the request when recording does' do
    allow(RequestLatency).to receive(:record_request).and_raise('recording broke')

    expect(described_class.new(app_returning(200)).call(env).first).to eq(200)
  end
end
