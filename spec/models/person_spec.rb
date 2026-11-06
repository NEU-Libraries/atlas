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

  describe '.valid_orcid?' do
    it 'accepts an iD whose check character is right, including X' do
      %w[0000-0002-1825-0097 0000-0001-5109-3700 0000-0002-1694-233X].each do |orcid|
        expect(described_class.valid_orcid?(orcid)).to be(true), orcid
      end
    end

    it 'refuses a wrong check character, a URL form or a malformed iD' do
      %w[0000-0002-1825-0098 https://orcid.org/0000-0002-1825-0097 0000000218250097 0000-0002-1825-009x].each do |orcid|
        expect(described_class.valid_orcid?(orcid)).to be(false), orcid
      end
    end
  end

  describe '.profile_fields' do
    it 'keeps only the profile keys sent, stripped' do
      expect(described_class.profile_fields('bio' => ' Hi ', 'nuid' => '1')).to eq('bio' => 'Hi')
    end

    it 'refuses a blank display_name with its code' do
      expect { described_class.profile_fields('display_name' => ' ') }
        .to raise_error(Exceptions::PersonProfileError) { |e| expect(e.code).to eq(:blank_display_name) }
    end
  end
end
