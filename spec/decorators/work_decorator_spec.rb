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

    # "sometime before 1921" is a real encoding and the whole date some records
    # have. It rendered nothing at all, because the row keyed off the start.
    it 'spells out an end point that stands alone' do
      work = decorate_with(date_created_end:           Time.zone.parse('1921-01-01'),
                           date_created_end_precision: 'year')

      expect(work.mods_row(:date_created)).to eq('<dt>Date created</dt><dd>before 1921</dd>')
    end

    it 'still qualifies an end-only date' do
      work = decorate_with(date_created_end:           Time.zone.parse('1921-01-01'),
                           date_created_end_precision: 'year',
                           date_created_qualifier:     'approximate')

      expect(work.mods_row(:date_created)).to eq('<dt>Date created</dt><dd>before circa 1921</dd>')
    end

    # A record whose date is not w3cdtf has no value to format. Showing what
    # the cataloguer wrote beats a row they filled in that no reader sees.
    it 'renders the literal a record wrote in something other than w3cdtf' do
      expect(decorate_with(date_created_text: '19uu').mods_row(:date_created))
        .to eq('<dt>Date created</dt><dd>19uu</dd>')
    end

    it 'prefers the parsed date over the literal when it has both' do
      work = decorate_with(date_created:           Time.zone.parse('1935-01-01'),
                           date_created_precision: 'year',
                           date_created_text:      'ignored')

      expect(work.mods_row(:date_created)).to eq('<dt>Date created</dt><dd>1935</dd>')
    end

    it 'omits the row entirely when the record gave no date at all' do
      expect(decorate_with.mods_row(:date_created)).to eq('')
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

    # A text roleTerm is free text a cataloguer wrote, and it has to survive as
    # itself -- the corpus carries Photographer, Wrangler and the rest.
    it 'leaves an unrecognised role term as the record wrote it' do
      expect(named({ name: 'Doe, Jane', roles: ['Wrangler'] }))
        .to eq('<dt>Wrangler</dt><dd><p>Doe, Jane</p></dd>')
    end

    # An unlisted CODE is a typo, not a label. It fell through to itself, so
    # "zzz" became a row heading -- the outcome suppressing displayLabel exists
    # to prevent. The name still renders; losing it over a typo is worse.
    it 'files a name under an unlisted MARC code apart, rather than labelling the row with it' do
      expect(named({ name: 'Delta, Dee', roles: ['zzz'] }))
        .to eq('<dt>Other contributors</dt><dd><p>Delta, Dee</p></dd>')
    end

    # The unknown-role label is a last resort, not a per-role one. Applied per
    # role, a name carrying "aut" and a typo'd "qqq" appeared twice -- the
    # second time under a role the record never asserted.
    it 'does not repeat a name under the unknown-role label when one role resolved' do
      expect(named({ name: 'Multi, M', roles: %w[aut qqq] }))
        .to eq('<dt>Author</dt><dd><p>Multi, M</p></dd>')
    end

    it 'still uses the unknown-role label when every role on the name is unlisted' do
      expect(named({ name: 'Multi, M', roles: %w[qqq zzz] }))
        .to eq('<dt>Other contributors</dt><dd><p>Multi, M</p></dd>')
    end

    # MODS makes the namePart optional, so a name element carrying only a role
    # rendered a labelled empty row. An access copy stored before neu-mods
    # dropped these still carries one.
    it 'skips a name with a role and no name text' do
      aggregate_failures do
        expect(named({ name: nil, roles: ['edt'] })).to eq('')
        expect(named({ name: '   ', roles: ['edt'] })).to eq('')
        expect(named({ name: nil, roles: ['edt'] }, { name: 'Roe, Ann', roles: ['edt'] }))
          .to eq('<dt>Editor</dt><dd><p>Roe, Ann</p></dd>')
      end
    end
  end

  # ActiveSupport#titleize splits on hyphens and capitalises every word, so an
  # authorised term came back as one that is not in the vocabulary.
  describe 'a controlled term is capitalised, not titleized' do
    it 'leaves the inside of a hyphenated authority term alone' do
      expect(decorate_with(format: ['black-and-white negatives']).mods_row(:format))
        .to eq('<dt>Format</dt><dd><p>Black-and-white negatives</p></dd>')
    end

    it 'upcases only the first word of a closed-vocabulary value' do
      aggregate_failures do
        expect(decorate_with(issuance: ['single unit']).mods_row(:issuance))
          .to eq('<dt>Issuance</dt><dd><p>Single unit</p></dd>')
        expect(decorate_with(digital_origin: ['reformatted digital']).mods_row(:digital_origin))
          .to eq('<dt>Digital origin</dt><dd><p>Reformatted digital</p></dd>')
      end
    end

    it 'leaves a value that opens on a digit untouched' do
      expect(decorate_with(format: ['1 online resource']).mods_row(:format))
        .to eq('<dt>Format</dt><dd><p>1 online resource</p></dd>')
    end
  end

  describe 'the rows that carry a repeatable element' do
    subject(:work) { from_fixture }

    # A :many field renders one <dd> per value. Built inline because the
    # coverage fixture carries no plain repeatable row with two values.
    it 'renders every value of a repeatable element, not just the first' do
      row = decorate_with(genres: %w[Photographs Negatives]).mods_row(:genres)

      expect(row).to eq('<dt>Genres</dt><dd><p>Photographs</p></dd><dd><p>Negatives</p></dd>')
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

    # objectPart="subtitles" says the SUBTITLES are Spanish. Rendered flat, the
    # row said the resource was -- which is what a captioned video carries.
    it 'qualifies a language the record attached to part of the object' do
      row = decorate_with(languages: [{ term: 'English' },
                                      { term: 'Spanish', object_part: 'subtitles' }]).mods_row(:languages)

      expect(row).to eq('<dt>Languages</dt><dd><p>English</p></dd><dd><p>Spanish (subtitles)</p></dd>')
    end

    it 'joins a script into the same qualification rather than a second bracket' do
      row = decorate_with(languages: [{ term: 'Russian', script: 'Cyrillic' }]).mods_row(:languages)

      expect(row).to eq('<dt>Languages</dt><dd><p>Russian (Cyrillic)</p></dd>')
    end

    # In MODS @invalid means cancelled, superseded or wrong. Unmarked, a dead
    # ISBN is what a reader chasing an old citation will try to use.
    it 'marks an identifier the record calls invalid' do
      row = decorate_with(identifiers: [{ type: 'isbn', value: '0000000000', invalid: true },
                                        { type: 'doi', value: '10.1/x', invalid: false }]).mods_row(:identifiers)

      expect(row).to eq('<dt>Identifiers</dt><dd><p>ISBN: 0000000000 (invalid)</p></dd>' \
                        '<dd><p>DOI: 10.1/x</p></dd>')
    end

    # The gem keeps a legacy contents list's line breaks because there the
    # break is the structure. linkify would collapse a lone newline to a space.
    it 'renders a newline-separated contents list as one value per line' do
      row = decorate_with(table_of_contents: ["Ch 1\nCh 2", 'Ch 3 -- Ch 4']).mods_row(:table_of_contents)

      expect(row).to eq('<dt>Contents</dt><dd><p>Ch 1</p></dd><dd><p>Ch 2</p></dd>' \
                        '<dd><p>Ch 3 -- Ch 4</p></dd>')
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

    # Projection and coordinates used to share one slot and collide on a
    # space, so a reader could not see where the projection name ended.
    it 'composes cartographics for display, which the gem leaves structured' do
      mapped = decorate_with(map_data: [Metadata::Fields::MapData.new(
        scale: '1:24,000', projection: 'UTM', coordinates: 'W 71 03 00'
      )])
      expect(mapped.mods_row(:map_data))
        .to eq('<dt>Map data</dt><dd><p>1:24,000 ; UTM ; W 71 03 00</p></dd>')
    end

    # A geotagged photograph is an ordinary record and never claimed a scale,
    # so "Scale not given" put an editorial complaint on the page -- the
    # mistake DATE_FORMATS exists to avoid, in a new place.
    it 'renders only the parts a map gives, asserting nothing about a missing scale' do
      mapped = decorate_with(map_data: [Metadata::Fields::MapData.new(coordinates: 'W 71 03 00')])
      expect(mapped.mods_row(:map_data))
        .to eq('<dt>Map data</dt><dd><p>W 71 03 00</p></dd>')
    end

    it 'omits a cartographics entry that carries nothing at all' do
      expect(decorate_with(map_data: [Metadata::Fields::MapData.new]).mods_row(:map_data)).to eq('')
    end
  end

  # "Estuaries, 24(3), pp. 210-218, 1998" -- the citation. Every part is
  # optional, and each branch has to degrade without leaving punctuation behind.
  describe "a work's position in its host" do
    def hosted(**attrs)
      decorate_with(host_collections: [Metadata::Fields::HostCollection.new(**attrs)])
        .mods_row(:host_collections)
    end

    def host_value(**attrs)
      hosted(**attrs).sub('<dt>Host collections</dt><dd><p>', '').sub('</p></dd>', '')
    end

    it 'parenthesises the issue when a volume precedes it' do
      expect(host_value(title: 'Estuaries', volume: '24', issue: '3')).to eq('Estuaries, 24(3)')
    end

    # "(3)" reads as an issue only after a volume. Alone it is a bare
    # parenthesis, so the issue is spelled out instead.
    it 'spells out an issue that stands without a volume' do
      expect(host_value(title: 'Estuaries', issue: '3')).to eq('Estuaries, no. 3')
    end

    it 'renders a volume alone and a page range alone' do
      aggregate_failures do
        expect(host_value(title: 'Estuaries', volume: '24')).to eq('Estuaries, 24')
        expect(host_value(title: 'Estuaries', start_page: '210', end_page: '218'))
          .to eq('Estuaries, pp. 210-218')
        expect(host_value(title: 'Estuaries', start_page: '210')).to eq('Estuaries, p. 210')
      end
    end

    # The position describes this work and no other record holds it, so a host
    # block that named no title must not take it down with it.
    it 'renders the position alone when the host names no title' do
      expect(host_value(issue: '3', start_page: '210')).to eq('no. 3, p. 210')
    end

    it 'renders nothing for a host entry carrying neither title nor position' do
      expect(hosted).to eq('')
    end

    # part/date is the article's year within the host, and it closes the
    # citation.
    it 'closes the citation with the date the record gave' do
      expect(host_value(title: 'Estuaries', volume: '24', issue: '3',
                        start_page: '210', end_page: '218', date: '1998'))
        .to eq('Estuaries, 24(3), pp. 210-218, 1998')
    end

    # detail/@type is an open string, so the caption is the label the
    # cataloguer wrote and the type is the fallback when they wrote none.
    it 'labels a detail with its caption, falling back to its type' do
      aggregate_failures do
        expect(host_value(title: 'Salt Marshes', details: [
                            Metadata::Fields::HostDetail.new(type: 'chapter', caption: 'chap.',
                                                             number: '7', title: 'Tidal Range')
                          ])).to eq('Salt Marshes, chap. 7, Tidal Range')
        expect(host_value(title: 'Salt Marshes', details: [
                            Metadata::Fields::HostDetail.new(type: 'section', number: '2')
                          ])).to eq('Salt Marshes, Section 2')
      end
    end

    it 'keeps the unit on an extent measured in something other than pages' do
      expect(host_value(title: 'Field Recordings', extents: [
                          Metadata::Fields::HostExtent.new(unit: 'minutes', start: '0', end: '45')
                        ])).to eq('Field Recordings, minutes 0-45')
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

  # A record whose only titleInfo is a variant still gets a main_title model,
  # holding five empty strings. An object is never blank, so the row rendered a
  # bold "Title" heading over blank space -- a title the system looked to have
  # lost rather than one the record never gave.
  context 'when the record gives no primary title' do
    it 'omits the row for a parts model that composes to nothing' do
      work = decorate_with(main_title:        Metadata::Fields::TitleInfo.new(title: '', non_sort: ''),
                           alternative_title: ['Only Alternative'])

      aggregate_failures do
        expect(work.title).to eq('')
        expect(work.mods_row(:alternative_title))
          .to eq('<dt>Alternative title</dt><dd><p>Only Alternative</p></dd>')
      end
    end

    it 'omits the row for a titleInfo carrying only a subTitle' do
      work = decorate_with(main_title: Metadata::Fields::TitleInfo.new(title: '', subtitle: 'A Subtitle'))

      expect(work.title).to eq('')
    end

    it 'omits the row when there is no access copy at all' do
      expect(Work.new.decorate.title).to eq('')
    end
  end
end
