# frozen_string_literal: true

require 'rails_helper'

# Sends every row of ServiceMatrix (spec/support/matrices/service_matrix.rb).
# See docs/testing.md.
RSpec.describe 'Service matrix', type: :request, default_auth: false do
  # Production's guard, so a permitted reset would show as a miss instead of
  # wiping the world.
  before { stub_const('RepositoryReset::RESETTABLE_ENVS', []) }

  # A Work for the fixity check to name: the checker records against a real
  # OCFL object.
  def build_subjects(_state)
    @work ||= WorkCreator.call(parent_id: CollectionCreator.call(parent_id: public_community!.noid).noid)
    { check: { object: "urn:neu-drs:#{@work.noid}", checked_at: '2026-10-27T03:12:09Z', version: 'v1',
               algorithm: 'sha512', files: 3, result: 'pass', findings: [], checker: 'matrix' } }
  end

  it_behaves_like 'a flat access matrix', ServiceMatrix
end
