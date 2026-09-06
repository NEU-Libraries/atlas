# frozen_string_literal: true

require 'rails_helper'

# The MODS HTML projection is WorkDecorator::DISPLAY rendered in order, so
# asserting a row IS asserting the rendered HTML. Rows are asserted one field at
# a time rather than as one blob, so a failure names the field that regressed.
# A blank field must omit the whole row -- label and value -- rather than emit
# an empty <dd> under a heading.
RSpec.describe WorkDecorator do
  # Decorate a bare Work whose #mods returns a controlled access copy, so the
  # gating is asserted directly without depending on the WorkCreator template.
  def decorate_with(**mods_attrs)
    mods = Metadata::MODS.new(**mods_attrs)
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }.decorate
  end

  def from_fixture
    xml = file_fixture('mods-coverage.xml').read
    mods = Metadata::MODS.new.tap { |m| m.assign_attributes(NEU::MODS::Document.parse(xml).to_h) }
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }.decorate
  end

  context 'when every field is blank (a sparse record)' do
    subject(:work) { decorate_with }

    it 'omits every row, so the whole list renders empty' do
      expect(work.mods_rows).to eq('')
    end

    it 'omits the label as well as the value, field by field' do
      aggregate_failures do
        WorkDecorator::DISPLAY.each do |row|
          expect(work.mods_row(row[:field])).to eq(''), "#{row[:field]} rendered something"
        end
      end
    end
  end

  # A date parses to 1 January when the record gave only a year, so formatting
  # every date as %Y-%m-%d prints a month and a day the record never claimed --
  # indistinguishable from a record that did claim them.
  describe 'a date renders only as finely as the record declared it' do
    def date_row(precision)
      decorate_with(date_created:           Time.zone.parse('2026-02-20'),
                    date_created_precision: precision).mods_row(:date_created)
    end

    def qualified_row(qualifier)
      decorate_with(date_created:           Time.zone.parse('1935-01-01'),
                    date_created_precision: 'year',
                    date_created_qualifier: qualifier).mods_row(:date_created)
    end

    it 'renders a day-precision date in full' do
      expect(date_row('day')).to eq('<dt>Date created</dt><dd>2026-02-20</dd>')
    end

    it 'renders a month-precision date without the day' do
      expect(date_row('month')).to eq('<dt>Date created</dt><dd>2026-02</dd>')
    end

    it 'renders a year-precision date as the year alone, never 2026-01-01' do
      expect(date_row('year')).to eq('<dt>Date created</dt><dd>2026</dd>')
    end

    it 'falls back to the full date when the precision is absent or unknown' do
      aggregate_failures do
        expect(date_row(nil)).to eq('<dt>Date created</dt><dd>2026-02-20</dd>')
        expect(date_row('century')).to eq('<dt>Date created</dt><dd>2026-02-20</dd>')
      end
    end

    # A cataloguer marked the date doubtful and the page stated it as fact.
    # These are the conventions cataloguers already use, so they read as
    # intended rather than as a rendering bug. A qualifier hidden in a title
    # attribute leaves a reader with a bare date they take as certain.
    it 'renders the qualifier into the date string, not into a tooltip' do
      aggregate_failures do
        expect(qualified_row('approximate')).to eq('<dt>Date created</dt><dd>circa 1935</dd>')
        expect(qualified_row('inferred')).to eq('<dt>Date created</dt><dd>[1935]</dd>')
        expect(qualified_row('questionable')).to eq('<dt>Date created</dt><dd>1935?</dd>')
      end
    end

    it 'shows an unrecognised qualifier rather than dropping what the record said' do
      expect(qualified_row('guessed')).to eq('<dt>Date created</dt><dd>1935 (guessed)</dd>')
    end

    it 'renders nothing extra when the record asserted certainty' do
      expect(qualified_row(nil)).to eq('<dt>Date created</dt><dd>1935</dd>')
    end

    # A ranged record rendered as a single year, indistinguishable from one
    # that claimed a single certain date.
    it 'renders both ends of a range, each at its own precision' do
      work = decorate_with(date_created:               Time.zone.parse('1935-06-01'),
                           date_created_precision:     'month',
                           date_created_end:           Time.zone.parse('1940-01-01'),
                           date_created_end_precision: 'year')

      expect(work.mods_row(:date_created)).to eq('<dt>Date created</dt><dd>1935-06-1940</dd>')
    end

    it 'wraps the whole range in the qualifier, not just its start' do
      work = decorate_with(date_created:               Time.zone.parse('1935-01-01'),
                           date_created_precision:     'year',
                           date_created_end:           Time.zone.parse('1940-01-01'),
                           date_created_end_precision: 'year',
                           date_created_qualifier:     'approximate')

      expect(work.mods_row(:date_created)).to eq('<dt>Date created</dt><dd>circa 1935-1940</dd>')
    end

    it 'formats the other two dates from their own precision' do
      work = decorate_with(date_issued: Time.zone.parse('2025-06-01'), date_issued_precision: 'month',
                           copyright_date: Time.zone.parse('2025-01-01'), copyright_date_precision: 'year')
      aggregate_failures do
        expect(work.mods_row(:date_issued)).to eq('<dt>Date issued</dt><dd>2025-06</dd>')
        expect(work.mods_row(:copyright_date)).to eq('<dt>Copyright date</dt><dd>2025</dd>')
      end
    end
  end

  # A nil label rendered an empty <dt>, so the name read as a value of the field
  # above it and a screen reader announced it under an empty term.
  describe 'a name renders under a real label' do
    def named(*names)
      decorate_with(names: names.map { |n| Metadata::Fields::Name.new(**n) }).mods_row(:names)
    end

    it 'labels a role-less name Creator rather than nothing' do
      expect(named({ name: 'Center for Atypical Language Interpreting', roles: [] }))
        .to eq('<dt>Creator</dt><dd><p>Center for Atypical Language Interpreting</p></dd>')
    end

    it 'merges a role-less name into an explicit Creator group' do
      expect(named({ name: 'Doe, Jane', roles: ['Creator'] }, { name: 'Roe, Ann', roles: [] }))
        .to eq('<dt>Creator</dt><dd><p>Doe, Jane</p></dd><dd><p>Roe, Ann</p></dd>')
    end

    it 'renders two role-less names under one Creator label, not two empty ones' do
      expect(named({ name: 'One', roles: [] }, { name: 'Two', roles: [] }))
        .to eq('<dt>Creator</dt><dd><p>One</p></dd><dd><p>Two</p></dd>')
    end

    it 'translates a MARC relator code into its label' do
      expect(named({ name: 'Doe, Jane', roles: ['aut'] }))
        .to eq('<dt>Author</dt><dd><p>Doe, Jane</p></dd>')
    end

    it 'groups a code and its text term together, since they name one role' do
      expect(named({ name: 'Doe, Jane', roles: ['aut'] }, { name: 'Roe, Ann', roles: ['Author'] }))
        .to eq('<dt>Author</dt><dd><p>Doe, Jane</p></dd><dd><p>Roe, Ann</p></dd>')
    end

    # Two roles is two assertions, so the name belongs under both headings.
    it 'renders a name under every role it declares' do
      expect(named({ name: 'Doe, Jane', roles: %w[aut ctb] }))
        .to eq('<dt>Author</dt><dd><p>Doe, Jane</p></dd>' \
               '<dt>Contributor</dt><dd><p>Doe, Jane</p></dd>')
    end

    it 'leaves an unrecognised role as the record wrote it' do
      expect(named({ name: 'Doe, Jane', roles: ['Wrangler'] }))
        .to eq('<dt>Wrangler</dt><dd><p>Doe, Jane</p></dd>')
    end
  end

  describe 'the rows that carry a repeatable element' do
    subject(:work) { from_fixture }

    # A :many field renders one <dd> per value. Built inline because the
    # coverage fixture carries no plain repeatable row with two values.
    it 'renders every value of a repeatable element, not just the first' do
      row = decorate_with(languages: %w[English French]).mods_row(:languages)

      expect(row).to eq('<dt>Languages</dt><dd><p>English</p></dd><dd><p>French</p></dd>')
    end

    it 'renders the three fields that were stored and never displayed' do
      aggregate_failures do
        expect(work.mods_row(:format)).to eq('<dt>Format</dt><dd><p>Electronic</p></dd>')
        expect(work.mods_row(:extent))
          .to eq('<dt>Extent</dt><dd><p>1 online resource (24 pages)</p></dd>')
        expect(work.mods_row(:identifiers))
          .to eq('<dt>Identifiers</dt><dd><p>DOI: 10.17760/D20123456</p></dd>')
      end
    end

    it 'labels the series field Series, not Related Items' do
      expect(work.mods_row(:related_series)).to eq('<dt>Series</dt><dd><p>A Series</p></dd>')
    end

    it 'renders the host collection, which had no row at all' do
      expect(work.mods_row(:host_collections))
        .to eq('<dt>Host collections</dt><dd><p>Estuaries, 24(3), pp. 210-218</p></dd>')
    end

    it 'renders a code-only language as its name' do
      expect(work.mods_row(:languages)).to eq('<dt>Languages</dt><dd><p>English</p></dd>')
    end
  end

  describe 'the rows whose markup is more than a label and a value' do
    subject(:work) { from_fixture }

    it 'groups a note under its own type' do
      expect(work.mods_row(:notes)).to eq(
        '<dt>Statement of responsibility</dt><dd><p>Prepared by the Working Group.</p></dd>' \
        '<dt>Notes</dt><dd><p>A general note.</p></dd>'
      )
    end

    it 'leads a related item with the relationship it declares' do
      expect(work.mods_row(:related_items))
        .to eq('<dt>Related items</dt><dd><p>Other Format: The Print Edition</p></dd>')
    end

    it 'renders a location part by part, so a URL linkifies and a shelf mark does not' do
      located = decorate_with(location: [Metadata::Fields::Location.new(
        physical_location: 'Snell Library', shelf_location: 'PS3552 .E1', url: 'https://example.org/i'
      )])
      expect(located.mods_row(:location)).to include(
        '<dt>Location</dt><dd><p>Snell Library</p></dd><dd><p>PS3552 .E1</p></dd>',
        '<a href="https://example.org/i"'
      )
    end

    it 'composes cartographics for display, which the gem leaves structured' do
      mapped = decorate_with(map_data: [Metadata::Fields::MapData.new(
        scale: '1:24,000', projection: 'UTM', coordinates: 'W 71 03 00'
      )])
      expect(mapped.mods_row(:map_data))
        .to eq('<dt>Map data</dt><dd><p>1:24,000 ; UTM W 71 03 00</p></dd>')
    end

    it 'says so when a map gives no scale, rather than rendering a bare projection' do
      mapped = decorate_with(map_data: [Metadata::Fields::MapData.new(coordinates: 'W 71 03 00')])
      expect(mapped.mods_row(:map_data))
        .to eq('<dt>Map data</dt><dd><p>Scale not given ; W 71 03 00</p></dd>')
    end
  end

  # A reader shown a bare 10.1234/x cannot tell it is a DOI, and a display
  # cannot decide to linkify it.
  describe 'an identifier says what kind of identifier it is' do
    def identified(*entries)
      decorate_with(identifiers: entries.map { |e| Metadata::Fields::Identifier.new(**e) })
        .mods_row(:identifiers)
    end

    it 'leads the value with its type, upcased because these are codes' do
      expect(identified({ type: 'doi', value: '10.1234/x' }))
        .to eq('<dt>Identifiers</dt><dd><p>DOI: 10.1234/x</p></dd>')
    end

    it 'renders an untyped identifier as the bare value' do
      expect(identified({ type: nil, value: '2047/D1' }))
        .to eq('<dt>Identifiers</dt><dd><p>2047/D1</p></dd>')
    end

    it 'renders each identifier on its own line' do
      expect(identified({ type: 'doi', value: '10.1234/x' }, { type: 'COLID', value: 'bdr:1' }))
        .to eq('<dt>Identifiers</dt><dd><p>DOI: 10.1234/x</p></dd><dd><p>COLID: bdr:1</p></dd>')
    end
  end

  # "Doe, J., Department of Physics" is how a reader tells one J. Doe from
  # another, and it is the basis of any future department browse.
  describe 'a creator carries its affiliation' do
    def named(*names)
      decorate_with(names: names.map { |n| Metadata::Fields::Name.new(**n) }).mods_row(:names)
    end

    it 'attaches the affiliation to the name it belongs to' do
      expect(named({ name: 'Doe, Jane', roles: ['Creator'],
                     affiliation: ['Department of Physics', 'Northeastern University'] }))
        .to eq('<dt>Creator</dt><dd><p>Doe, Jane — Department of Physics, Northeastern University</p></dd>')
    end

    # Two physicists in different departments still belong under one heading.
    it 'does not let the affiliation become a grouping key' do
      expect(named({ name: 'Doe, Jane', roles: ['Creator'], affiliation: ['Physics'] },
                   { name: 'Roe, Ann', roles: ['Creator'], affiliation: ['Chemistry'] }))
        .to eq('<dt>Creator</dt><dd><p>Doe, Jane — Physics</p></dd><dd><p>Roe, Ann — Chemistry</p></dd>')
    end

    it 'renders a bare name when there is no affiliation' do
      expect(named({ name: 'Doe, Jane', roles: ['Creator'], affiliation: [] }))
        .to eq('<dt>Creator</dt><dd><p>Doe, Jane</p></dd>')
    end
  end

  # A cataloguer was given a spreadsheet column for each of these and the value
  # reached no reader.
  describe 'the corpus fields that had no row' do
    subject(:work) { from_fixture }

    it 'renders the plain rows' do
      aggregate_failures do
        expect(work.mods_row(:place_of_publication))
          .to eq('<dt>Place of publication</dt><dd><p>Boston</p></dd>')
        expect(work.mods_row(:issuance)).to eq('<dt>Issuance</dt><dd><p>Monographic</p></dd>')
        expect(work.mods_row(:frequency)).to eq('<dt>Frequency</dt><dd><p>Quarterly</p></dd>')
        expect(work.mods_row(:reformatting_quality))
          .to eq('<dt>Reformatting quality</dt><dd><p>Preservation</p></dd>')
        expect(work.mods_row(:table_of_contents))
          .to eq('<dt>Contents</dt><dd><p>Chapter 1 -- Chapter 2</p></dd>')
        expect(work.mods_row(:classification))
          .to eq('<dt>Photo category</dt><dd><p>PS3552.E1</p></dd>')
      end
    end

    it 'renders a note about the object apart from a note about the work' do
      expect(work.mods_row(:physical_description_notes))
        .to eq('<dt>Physical description note</dt><dd><p>Scanned at 600 dpi.</p></dd>')
    end

    # One row per subject, not one per axis. Split apart, a fragment of a
    # heading and a whole heading read as two independent subjects.
    describe 'the assembled subject heading' do
      it 'joins a pre-coordinated heading the way a cataloguer built it' do
        expect(work.mods_row(:subject_headings))
          .to include('<dd><p>Salt marshes -- Massachusetts -- 20th century</p></dd>')
      end

      it 'gives every axis one row under one label' do
        expect(work.mods_row(:subject_headings))
          .to eq('<dt>Subjects and keywords</dt>' \
                 '<dd><p>Interpreting</p></dd>' \
                 '<dd><p>Boston (Mass.)</p></dd>' \
                 '<dd><p>21st century</p></dd>' \
                 '<dd><p>Smith, John</p></dd>' \
                 '<dd><p>Field recordings</p></dd>' \
                 '<dd><p>Cabinetmakers</p></dd>' \
                 '<dd><p>Salt marshes -- Massachusetts -- 20th century</p></dd>' \
                 '<dd><p>The Great Gatsby</p></dd>' \
                 '<dd><p>United States -- New York -- Parksville</p></dd>')
      end

      # A MARC GAC code is not heading text, so v1 showed it nowhere and this
      # does not either -- it stays projected for the index alone.
      it 'leaves the geographic code out of the heading' do
        expect(work.mods_row(:subject_headings)).not_to include('n-us-ny')
      end

      it 'gives the per-axis fields no row of their own' do
        aggregate_failures do
          %i[topical_subjects geographic_subjects temporal_subjects title_subjects
             personal_name_subjects genre_subjects occupation_subjects
             geographic_code_subjects hierarchical_geographic_subjects].each do |field|
            expect(work.mods_row(field)).to eq('')
          end
        end
      end
    end

    # Cataloguing provenance rather than description, so it renders nowhere.
    # It stays projected onto the access copy for the API and the OAI
    # crosswalk; NOT_DISPLAYED records that split.
    it 'keeps the cataloguing provenance out of the descriptive list' do
      expect(work.mods_rows).not_to include('Northeastern University Libraries')
    end

    # typeOfResource says "still image" where the Content facet says "Image",
    # and a reader looking at a photograph needs neither. The value stays
    # indexed and stays in dc:type, where a harvester wants the vocabulary.
    it 'keeps the resource type out of the descriptive list' do
      aggregate_failures do
        expect(work.mods_row(:resource_type)).to eq('')
        expect(work.mods_rows).not_to include('Resource type')
      end
    end
  end

  # Collapsing every accessCondition under one label presented an access
  # restriction to a reader as a licence.
  describe 'access conditions render apart' do
    it 'labels a restriction and a licence separately' do
      work = from_fixture
      aggregate_failures do
        expect(work.mods_row(:restriction_on_access))
          .to eq('<dt>Restriction on access</dt><dd><p>Northeastern University only.</p></dd>')
        expect(work.mods_row(:use_and_reproduction))
          .to eq('<dt>Use and reproduction</dt><dd><p>CC BY 4.0</p></dd>')
      end
    end

    it 'suppresses the combined value when a typed one already rendered' do
      expect(from_fixture.mods_row(:access_condition)).to eq('')
    end

    it 'falls back to the combined value, which alone carries an untyped condition' do
      work = decorate_with(access_condition: 'No known restrictions.')
      expect(work.mods_row(:access_condition))
        .to eq('<dt>Access condition</dt><dd><p>No known restrictions.</p></dd>')
    end
  end

  # MODS has no element for a subscript, so a chemistry record escapes the tags
  # into the title's own text node. Escaping the <dd> printed those tags to the
  # reader; sanitising renders them.
  context 'when the title carries enhanced-text markup' do
    def title_html(title)
      decorate_with(main_title: Metadata::Fields::TitleInfo.new(title: title)).title
    end

    it 'renders the subscripts a record escaped into the title' do
      expect(title_html('Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>'))
        .to eq('<dt>Title</dt><dd>Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub></dd>')
    end

    it 'renders a superscript' do
      expect(title_html('E=mc<sup>2</sup>')).to eq('<dt>Title</dt><dd>E=mc<sup>2</sup></dd>')
    end

    it 'still escapes everything outside the two-tag allowlist' do
      expect(title_html('Steel & Iron')).to eq('<dt>Title</dt><dd>Steel &amp; Iron</dd>')
      expect(title_html('a <b>bold</b> claim'))
        .to eq('<dt>Title</dt><dd>a &lt;b&gt;bold&lt;/b&gt; claim</dd>')
    end

    it 'keeps the whole title when it holds a literal less-than' do
      expect(title_html('Resistivity at Ti <Tc in Bi<sub>2</sub>O'))
        .to eq('<dt>Title</dt><dd>Resistivity at Ti &lt;Tc in Bi<sub>2</sub>O</dd>')
    end

    it 'leaves plain_title raw -- the JSON views and the indexers read it as a value' do
      work = decorate_with(main_title: Metadata::Fields::TitleInfo.new(title: 'H<sub>2</sub>O'))

      expect(work.plain_title).to eq('H<sub>2</sub>O')
    end
  end
end
