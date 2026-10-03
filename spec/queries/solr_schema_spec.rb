# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SolrSchema do
  subject(:schema) do
    described_class.new(
      'fields'        => [{ 'name' => 'title_stem_tesim', 'type' => 'text_en', 'stored' => false }],
      'dynamicFields' => [{ 'name' => '*_tesim', 'type' => 'text_en', 'stored' => true },
                          { 'name' => '*_teim', 'type' => 'text_en', 'stored' => false },
                          { 'name' => '*_im', 'type' => 'text_en' },
                          { 'name' => 'attr_*', 'type' => 'text_en' }],
      'fieldTypes'    => [{ 'name' => 'text_en' }],
      'copyFields'    => [{ 'source' => 'title_tsim', 'dest' => 'title_stem_tesim' },
                          { 'source' => '*_tsim', 'dest' => 'title_stem_tesim' }]
    )
  end

  it 'lets an explicit field override the dynamic pattern it would match' do
    expect(schema.stored?('title_stem_tesim')).to be(false)
    expect(schema.stored?('subject_title_tesim')).to be(true)
  end

  it 'resolves a name against the longest matching dynamic pattern' do
    expect(schema.stored?('name_variant_teim')).to be(false)
  end

  it 'treats a property set on neither the field nor its type as stored' do
    expect(schema.stored?('a_im')).to be(true)
    expect(schema.stored?('attr_colour')).to be(true)
  end

  it 'knows only the names the schema defines' do
    expect(schema.known?('full_title_tsim')).to be(false)
    expect(schema.stored?('full_title_tsim')).to be(false)
  end

  it 'lists the named copyField sources and skips the wildcards' do
    expect(schema.copy_sources('title_stem_tesim')).to eq(['title_tsim'])
  end
end
