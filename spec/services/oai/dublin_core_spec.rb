# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OAI::DublinCore do
  def mods(**attrs)
    Metadata::MODS.new(**attrs)
  end

  def name(value, role)
    Metadata::Fields::Name.new(name: value, role: role)
  end

  it 'assembles the primary title from its parts' do
    record = mods(main_title: Metadata::Fields::TitleInfo.new(
      non_sort: 'The', title: 'Long Road', subtitle: 'a study', part_number: 'Volume 2'
    ))

    expect(described_class.call(record)[:title]).to eq(['The Long Road: a study. Volume 2'])
  end

  # A thesis advisor is not an author. Flattening every name into dc:creator
  # would push wrong attribution into a downstream catalogue.
  it 'splits names by role' do
    record = mods(names: [name('Ito, K.', 'creator'), name('Ali, N.', 'Thesis advisor')])
    result = described_class.call(record)

    expect(result[:creator]).to eq(['Ito, K.'])
    expect(result[:contributor]).to eq(['Ali, N.'])
  end

  # The split matched the literal string "creator", so `aut` and `Author` --
  # the same claim written differently -- harvested as contributors.
  it 'reads a MARC relator code as the role it names' do
    record = mods(names: [name('Ito, K.', 'aut'), name('Ali, N.', 'ths')])
    result = described_class.call(record)

    expect(result[:creator]).to eq(['Ito, K.'])
    expect(result[:contributor]).to eq(['Ali, N.'])
  end

  # MODS makes mods:role optional. An empty role never matched "creator", so
  # every unroled name was silently demoted -- while the display labelled the
  # same name Creator.
  it 'harvests a role-less name as a creator, matching the display' do
    record = mods(names: [name('Center for Atypical Language Interpreting', nil)])
    result = described_class.call(record)

    expect(result[:creator]).to eq(['Center for Atypical Language Interpreting'])
    expect(result).not_to have_key(:contributor)
  end

  # A new subject axis passed every spec and was silently absent from oai_dc,
  # because the axes were asserted by name rather than derived. This is the
  # guard DISPLAY and SOLR_FIELDS already have, for the fourth consumer.
  it 'flattens every projected subject axis into dc:subject' do
    axes = NEU::MODS::FIELDS.keys.grep(/_subjects\z/) - [:hierarchical_geographic_subjects]

    expect(axes - described_class::SUBJECT_AXES).to be_empty
  end

  it 'names no axis the gem does not project' do
    expect(described_class::SUBJECT_AXES - NEU::MODS::FIELDS.keys).to be_empty
  end

  it 'flattens all five subject axes into dc:subject' do
    record = mods(topical_subjects: ['Physics'], geographic_subjects: ['Boston'],
                  temporal_subjects: ['1920s'], personal_name_subjects: ['Curie, M.'],
                  corporate_name_subjects: ['MIT'])

    expect(described_class.call(record)[:subject])
      .to contain_exactly('Physics', 'Boston', '1920s', 'Curie, M.', 'MIT')
  end

  # v1's dc:type was always empty: the `oai` gem skips a field called `type`
  # to dodge Ruby's deprecated Object#type.
  it 'populates dc:type from resource_type' do
    expect(described_class.call(mods(resource_type: 'text'))[:type]).to eq(['text'])
  end

  it 'prefers date_issued over date_created, at day precision' do
    record = mods(date_issued: Time.utc(2020, 5, 4, 13, 30), date_created: Time.utc(2019, 1, 1))

    expect(described_class.call(record)[:date]).to eq(['2020-05-04'])
  end

  it 'falls back to date_created' do
    expect(described_class.call(mods(date_created: Time.utc(2019, 1, 1)))[:date]).to eq(['2019-01-01'])
  end

  it 'maps the remaining simple fields' do
    record = mods(abstract: 'A summary', languages: %w[eng fra],
                  permanent_url: 'https://hdl.handle.net/2047/abc',
                  access_condition: 'In copyright')
    result = described_class.call(record)

    expect(result[:description]).to eq(['A summary'])
    expect(result[:language]).to eq(%w[eng fra])
    expect(result[:identifier]).to eq(['https://hdl.handle.net/2047/abc'])
    expect(result[:rights]).to eq(['In copyright'])
  end

  # An empty element is not just noise: oai_dc:dc would carry <dc:type/> with
  # nothing in it, which says the record has an empty type rather than none.
  it 'drops empty elements entirely' do
    expect(described_class.call(mods(resource_type: 'text')).keys).to eq([:type])
  end

  it 'survives a Work with no MODS row at all' do
    expect(described_class.call(nil)).to eq({})
  end
end
