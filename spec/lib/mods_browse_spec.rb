# frozen_string_literal: true

require 'rails_helper'

# The browse vocabulary is read by three files -- MODSIndexer, CitationIndexer
# and WorkDecorator -- so it is the one place a display marker and a Solr field
# can be kept in step. These are the guards on that: which axes it names, and
# which it deliberately does not.
RSpec.describe MODSBrowse do
  # Every axis the gem can report for a heading in the coverage corpus. Derived
  # from the fixture rather than listed, so a new MODS subject child arriving in
  # a gem bump fails here instead of quietly reaching no marker.
  let(:projected_axes) do
    xml = Rails.root.join('spec/fixtures/files/mods-coverage.xml').read
    NEU::MODS::Document.parse(xml).subject_headings.pluck(:axis).uniq
  end

  # hierarchical_geographic is the deliberate omission: the display composes a
  # path across the levels while the Places facet holds the narrowest level
  # alone, so the record has no single string that is both what a reader sees
  # and what the index holds.
  UNMARKED_AXES = %w[hierarchical_geographic].freeze

  it 'names every subject axis the corpus projects, or omits it on purpose' do
    expect(projected_axes - described_class::SUBJECT_AXES.keys - UNMARKED_AXES).to be_empty
  end

  it 'names no axis the gem cannot report' do
    unknown = described_class::SUBJECT_AXES.keys - projected_axes
    expect(unknown).to be_empty, "SUBJECT_AXES names #{unknown.inspect}, which no fixture heading reaches"
  end

  # An axis with no Solr field is a decision, not a blank: it says "marked for a
  # consumer, bucketed nowhere". A missing browse token would be the bug.
  it 'gives every axis a browse token' do
    axes = described_class::SUBJECT_AXES.values +
           [described_class::CREATOR, described_class::CONTRIBUTOR, described_class::LANGUAGE,
            described_class::PLACE_OF_PUBLICATION, described_class::PUBLISHER,
            described_class::PHOTO_CATEGORY]

    expect(axes.reject { |axis| axis.browse.present? }).to be_empty
  end

  # A browse token is what crosses the wire to Cerberus, which maps it to a
  # facet from its own config. Two axes sharing a token would make one of them
  # unaddressable.
  it 'keeps the browse tokens distinct' do
    tokens = described_class::SUBJECT_AXES.values.map(&:browse)
    expect(tokens).to eq(tokens.uniq)
  end

  # No Solr field name crosses the wire, so a facet rename in Cerberus needs no
  # Atlas release.
  it 'names the MODS axis rather than the Solr field' do
    described_class::SUBJECT_AXES.each_value do |axis|
      expect(axis.browse).not_to end_with('_ssim', '_tesim')
    end
  end

  describe '.name_axis' do
    def entry(roles) = Metadata::Fields::Name.new(name: 'Doe, Jane', roles: roles)

    it 'puts a name with a creator relator on the creator axis' do
      expect(described_class.name_axis(entry(['aut']))).to eq(described_class::CREATOR)
    end

    it 'puts a name with only other relators on the contributor axis' do
      expect(described_class.name_axis(entry(%w[ctb edt]))).to eq(described_class::CONTRIBUTOR)
    end

    # The axes are disjoint, so the facets are buckets rather than assertions.
    it 'keeps a name with both kinds of relator on the creator axis alone' do
      expect(described_class.name_axis(entry(%w[aut edt]))).to eq(described_class::CREATOR)
    end

    # Neither facet holds it, so neither axis may claim it.
    it 'puts a role-less name on no axis' do
      aggregate_failures do
        expect(described_class.name_axis(entry([]))).to be_nil
        expect(described_class.name_axis(entry(['']))).to be_nil
      end
    end
  end
end
