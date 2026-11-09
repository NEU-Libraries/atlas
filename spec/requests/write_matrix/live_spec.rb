# frozen_string_literal: true

require 'rails_helper'

# One state of the write matrix; spec/support/write_matrix_runner.rb runs it.
# default_auth: false, because the global admin default would be served everything.
RSpec.describe 'Write matrix', type: :request, default_auth: false do
  it_behaves_like 'the write matrix', :live
end
