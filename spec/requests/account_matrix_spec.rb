# frozen_string_literal: true

require 'rails_helper'

# Sends every row of AccountMatrix (spec/support/matrices/account_matrix.rb).
# See docs/testing.md.
RSpec.describe 'Account matrix', type: :request, default_auth: false do
  # The provisioning rows act on an account no tier signs in as, so a
  # permitted write cannot change a caller's own grants mid-run.
  def build_subjects(_state)
    User.find_by(nuid: AccountMatrix::TARGET[:nuid]) ||
      User.create!(email: AccountMatrix::TARGET[:email], password: SecureRandom.hex(16),
                   nuid: AccountMatrix::TARGET[:nuid], name: 'Target, Matrix', role: :standard)
    { standard: users[:standard] }
  end

  it_behaves_like 'a flat access matrix', AccountMatrix
end
