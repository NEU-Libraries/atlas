# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonCreator do
  after { Atlas.persister.wipe! }

  it 'creates a Person with the given attributes' do
    person = described_class.call(nuid: '001234567', display_name: 'Jane Doe', orcid: '0000-0002-1825-0097')

    expect(person).to be_a(Person)
    expect(person).to have_attributes(nuid: '001234567', display_name: 'Jane Doe', orcid: '0000-0002-1825-0097')
  end

  # People are public directory entries (v1 Faculty & Staff was world-browsable),
  # and Person has no parent to inherit a public ACL from — so the creator sets
  # it, which is what keeps the Person in gated discovery.
  it 'is born publicly readable' do
    person = described_class.call(nuid: '001234567', display_name: 'Jane Doe')

    expect(person.read_groups).to eq(['public'])
    expect(person.public?).to be(true)
  end

  it 'emits a single structural create audit row when an actor is present' do
    expect do
      @person = described_class.call(nuid: '001234567', display_name: 'Jane Doe', actor_nuid: '000000002')
    end.to change(AuditEvent, :count).by(1)

    ev = AuditEvent.find_by(resource_id: @person.id.to_s)
    expect(ev).to have_attributes(action: 'create', change_type: 'structural',
                                  actor_nuid: '000000002', resource_type: 'Person')
  end

  it 'skips the audit for internal callers with no actor' do
    expect { described_class.call(nuid: '001234567', display_name: 'Jane Doe') }
      .not_to change(AuditEvent, :count)
  end
end
