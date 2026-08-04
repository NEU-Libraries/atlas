# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Person do
  let(:person) { PersonCreator.call(nuid: '001234567', display_name: 'Doe, Jane') }

  after { Atlas.persister.wipe! }

  # A Person row can hold metadata keys the class does not declare: dropping an
  # attribute leaves its key in the document, and Atlas ships no migration to
  # sweep it out. Valkyrie ignores such a key, and this pins that behaviour —
  # the alternative is every affected Person failing to load.
  it 'reads a row whose metadata holds a key the class no longer declares' do
    injected = ActiveRecord::Base.connection.exec_update(
      "UPDATE orm_resources SET metadata = metadata || '{\"title\": [\"Professor\"]}'::jsonb
        WHERE id = $1", 'inject-stray-key', [person.id.to_s]
    )
    expect(injected).to eq(1) # the row has to carry the stray key for this to prove anything

    reloaded = described_class.find(person.noid)
    expect(reloaded.display_name).to eq('Doe, Jane')
    expect(reloaded).not_to respond_to(:title)
  end
end
