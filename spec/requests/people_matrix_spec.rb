# frozen_string_literal: true

require 'rails_helper'

# Sends every row of PeopleMatrix (spec/support/matrices/people_matrix.rb). See
# docs/testing.md.
RSpec.describe 'People matrix', type: :request, default_auth: false do
  # The Person every row names is :self's own, and the Community its
  # affiliation rows add and remove.
  def build_subjects(_state)
    person = Atlas.query.custom_queries.find_person_by_nuid(nuid: users[:self].nuid) ||
             PersonCreator.call(nuid: users[:self].nuid, display_name: 'Matrix, Self')
    { subject: person, community: @community ||= public_community! }
  end

  it_behaves_like 'a flat access matrix', PeopleMatrix
end
