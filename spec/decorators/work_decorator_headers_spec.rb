# frozen_string_literal: true

require 'rails_helper'

# How a row chooses the header it renders under: the record's own
# @displayLabel first, then an originInfo block's @eventType, then the field's
# name. work_decorator_spec.rb asserts what the rows CONTAIN; this file asserts
# what heads them.
RSpec.describe WorkDecorator, 'the header a row renders under' do
  # Every assertion in this file is about the <dt>, so a row arrives with its
  # browse markers stripped out of the <dd>. Those markers are a contract of
  # their own, asserted in work_decorator_spec; a change to them must fail
  # there and not here as well.
  def decorate_with(**mods_attrs)
    mods = Metadata::MODS.new(**mods_attrs)
    work = Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }.decorate
    allow(work).to receive(:mods_row).and_wrap_original do |original, *args|
      without_browse_markers(original.call(*args))
    end
    work
  end

  describe 'a record re-heads its own row with @displayLabel' do
    it 'replaces the default header on a plain row' do
      row = decorate_with(genres: [{ value: 'Photographs', display_label: 'Photo type' }])
            .mods_row(:genres)

      expect(row).to eq('<dt>Photo type</dt><dd><p>Photographs</p></dd>')
    end

    # A record that labels one of two values has asked for two headers. Values
    # group by the header they carry, not by the field they came from.
    it 'splits one field into two rows when two headers are asked for' do
      row = decorate_with(genres: [{ value: 'Photographs', display_label: 'Photo type' },
                                   { value: 'Negatives' }]).mods_row(:genres)

      expect(row).to eq('<dt>Photo type</dt><dd><p>Photographs</p></dd>' \
                        '<dt>Genres</dt><dd><p>Negatives</p></dd>')
    end

    it 're-heads the title, the abstract and the permanent URL from their companions' do
      work = decorate_with(
        main_title: Metadata::Fields::TitleInfo.new(title: 'A marsh'),
        main_title_display_label: 'Caption',
        abstract: 'A study.', abstract_display_label: 'Summary',
        permanent_url: 'http://hdl.handle.net/2047/1', permanent_url_display_label: 'Handle'
      )
      aggregate_failures do
        expect(work.mods_row(:main_title)).to eq('<dt>Caption</dt><dd>A marsh</dd>')
        expect(work.mods_row(:abstract)).to eq('<dt>Summary</dt><dd><p>A study.</p></dd>')
        expect(work.mods_row(:permanent_url)).to include('<dt>Handle</dt>')
      end
    end

    it 're-heads a name, a note, a subject and an identifier' do
      work = decorate_with(
        names:            [{ name: 'Adams, Ansel', roles: ['aut'], display_label: 'Photographer' }],
        notes:            [{ type: 'funding', value: 'NEH grant.', display_label: 'Support' }],
        subject_headings: [{ parts: ['Salt marshes'], display_label: 'Depicts' }],
        identifiers:      [{ type: 'doi', value: '10.1/x', display_label: 'Cite as' }]
      )
      aggregate_failures do
        expect(work.mods_row(:names)).to eq('<dt>Photographer</dt><dd><p>Adams, Ansel</p></dd>')
        expect(work.mods_row(:notes)).to eq('<dt>Support</dt><dd><p>NEH grant.</p></dd>')
        expect(work.mods_row(:subject_headings)).to eq('<dt>Depicts</dt><dd><p>Salt marshes</p></dd>')
        expect(work.mods_row(:identifiers)).to eq('<dt>Cite as</dt><dd><p>DOI: 10.1/x</p></dd>')
      end
    end
  end

  describe 'xlink:href hyperlinks the text beside it' do
    # mods:note is one of the fourteen elements MODS lets carry an xlink:href;
    # mods:genre is not, so a genre is the wrong element to demonstrate it on.
    it 'wraps the value in the link the record attached' do
      row = decorate_with(notes: [{ value: 'See the finding aid.',
                                    href:  'https://example.org/finding-aid' }]).mods_row(:notes)

      expect(row).to eq('<dt>Notes</dt>' \
                        '<dd><a href="https://example.org/finding-aid" rel="nofollow noopener" ' \
                        'target="_blank"><p>See the finding aid.</p></a></dd>')
    end

    # The librarians asked that a link require textual content. An element with
    # an href and no text projects no value at all, so no row appears.
    it 'renders nothing for a link with no text' do
      expect(decorate_with(notes: [{ value: '', href: 'https://example.org' }]).mods_row(:notes))
        .to eq('')
    end

    it 'links a licence from the accessCondition companion' do
      row = decorate_with(use_and_reproduction:      'CC BY 4.0',
                          use_and_reproduction_href: 'https://creativecommons.org/licenses/by/4.0/')
            .mods_row(:use_and_reproduction)

      expect(row).to include('<a href="https://creativecommons.org/licenses/by/4.0/"', '<p>CC BY 4.0</p>')
    end
  end

  describe 'the originInfo headers' do
    it 'heads the publisher row Publisher, and lets a label replace it' do
      aggregate_failures do
        expect(decorate_with(publication_information: [{ value: 'Beacon' }])
                 .mods_row(:publication_information))
          .to eq('<dt>Publisher</dt><dd><p>Beacon</p></dd>')
        expect(decorate_with(publication_information: [{ value: 'Beacon', display_label: 'Issued by' }])
                 .mods_row(:publication_information))
          .to eq('<dt>Issued by</dt><dd><p>Beacon</p></dd>')
      end
    end

    # @eventType names the event the block records, so it heads the row when
    # the record states no label of its own.
    it 'lets the block eventType head the row, below a displayLabel' do
      aggregate_failures do
        expect(decorate_with(publication_information: [{ value: 'The studio', event_type: 'production' }])
                 .mods_row(:publication_information))
          .to eq('<dt>production</dt><dd><p>The studio</p></dd>')
        expect(decorate_with(publication_information: [{ value: 'The studio', event_type: 'production',
                                                         display_label: 'Made by' }])
                 .mods_row(:publication_information))
          .to eq('<dt>Made by</dt><dd><p>The studio</p></dd>')
      end
    end

    # A place is headed by the date beside it: the same element records where a
    # thing was made and where it was published.
    it 'heads a place by the date element in its own block' do
      aggregate_failures do
        expect(decorate_with(place_of_publication: [{ value: 'Boston', date_elements: ['dateCreated'] }])
                 .mods_row(:place_of_publication))
          .to eq('<dt>Creation place</dt><dd><p>Boston</p></dd>')
        expect(decorate_with(place_of_publication: [{ value: 'Boston', date_elements: ['dateIssued'] }])
                 .mods_row(:place_of_publication))
          .to eq('<dt>Publication place</dt><dd><p>Boston</p></dd>')
      end
    end

    it 'reads a block carrying both dates as a publication' do
      row = decorate_with(place_of_publication: [{ value:         'Boston',
                                                   date_elements: %w[dateIssued dateCreated] }])
            .mods_row(:place_of_publication)

      expect(row).to eq('<dt>Publication place</dt><dd><p>Boston</p></dd>')
    end

    it 'defaults a dateless place to Publication place' do
      expect(decorate_with(place_of_publication: [{ value: 'Boston' }]).mods_row(:place_of_publication))
        .to eq('<dt>Publication place</dt><dd><p>Boston</p></dd>')
    end

    it 'lets a label and an event type outrank the date' do
      aggregate_failures do
        expect(decorate_with(place_of_publication: [{ value: 'Boston', date_elements: ['dateCreated'],
                                                      event_type: 'distribution' }])
                 .mods_row(:place_of_publication))
          .to eq('<dt>distribution</dt><dd><p>Boston</p></dd>')
        expect(decorate_with(place_of_publication: [{ value: 'Boston', date_elements: ['dateCreated'],
                                                      event_type: 'distribution', display_label: 'Sent from' }])
                 .mods_row(:place_of_publication))
          .to eq('<dt>Sent from</dt><dd><p>Boston</p></dd>')
      end
    end

    it 'heads a date row by its element, then its event type, then its label' do
      aggregate_failures do
        expect(decorate_with(date_created:           Time.zone.parse('1935-01-01'),
                             date_created_precision: 'year').mods_row(:date_created))
          .to eq('<dt>Date created</dt><dd>1935</dd>')
        expect(decorate_with(date_created: Time.zone.parse('1935-01-01'), date_created_precision: 'year',
                             date_created_event_type: 'production').mods_row(:date_created))
          .to eq('<dt>production</dt><dd>1935</dd>')
        expect(decorate_with(date_created: Time.zone.parse('1935-01-01'), date_created_precision: 'year',
                             date_created_event_type: 'production',
                             date_created_display_label: 'Photographed').mods_row(:date_created))
          .to eq('<dt>Photographed</dt><dd>1935</dd>')
      end
    end
  end

  describe 'originInfo/agent (MODS 3.8)' do
    it 'heads an agent by its role' do
      row = decorate_with(origin_agents: [{ name: 'Adams, Ansel', roles: ['pht'] }])
            .mods_row(:origin_agents)

      expect(row).to eq('<dt>Photographer</dt><dd><p>Adams, Ansel</p></dd>')
    end

    it 'lets the block label and event type outrank the role' do
      aggregate_failures do
        expect(decorate_with(origin_agents: [{ name: 'Adams, Ansel', roles: ['pht'],
                                               event_type: 'production' }]).mods_row(:origin_agents))
          .to eq('<dt>production</dt><dd><p>Adams, Ansel</p></dd>')
        expect(decorate_with(origin_agents: [{ name: 'Adams, Ansel', roles: ['pht'],
                                               event_type: 'production',
                                               display_label: 'Studio' }]).mods_row(:origin_agents))
          .to eq('<dt>Studio</dt><dd><p>Adams, Ansel</p></dd>')
      end
    end
  end

  describe 'a name carries its alternative name and its affiliation in one bracket' do
    it 'brackets the alternative name before the affiliation' do
      row = decorate_with(names: [{ name: 'Clemens, Samuel', roles: ['aut'],
                                    alternative_names: ['Twain, Mark'],
                                    affiliation: ['Department of English'] }]).mods_row(:names)

      expect(row).to eq('<dt>Author</dt>' \
                        '<dd><p>Clemens, Samuel [Twain, Mark, Department of English]</p></dd>')
    end
  end

  describe 'the headers the librarians renamed' do
    it 'heads the abstract Description and the location Physical location' do
      work = decorate_with(abstract: 'A study.',
                           location: [{ physical_location: 'Snell Library' }])
      aggregate_failures do
        expect(work.mods_row(:abstract)).to eq('<dt>Description</dt><dd><p>A study.</p></dd>')
        expect(work.mods_row(:location)).to eq('<dt>Physical location</dt><dd><p>Snell Library</p></dd>')
      end
    end

    it 'heads each relatedItem type in the words the librarians chose' do
      rows = {
        'constituent' => 'Includes', 'otherVersion' => 'Other versions',
        'otherFormat' => 'Other formats', 'preceding' => 'Preceded by',
        'succeeding' => 'Continued by', 'original' => 'Original version',
        'isReferencedBy' => 'Cited by'
      }
      aggregate_failures do
        rows.each do |type, label|
          expect(decorate_with(related_items: [{ type: type, title: 'A Thing' }]).mods_row(:related_items))
            .to eq("<dt>#{label}</dt><dd><p>A Thing</p></dd>"), type
        end
      end
    end

    it 'heads a host collection in the singular' do
      row = decorate_with(host_collections: [{ title: 'Estuaries' }]).mods_row(:host_collections)

      expect(row).to eq('<dt>Host collection</dt><dd><p>Estuaries</p></dd>')
    end
  end

  describe 'targetAudience' do
    it 'renders the audience a record names, which had no row before' do
      row = decorate_with(target_audience: [{ value: 'Undergraduates' }]).mods_row(:target_audience)

      expect(row).to eq('<dt>Target audience</dt><dd><p>Undergraduates</p></dd>')
    end
  end

  describe 'the display order' do
    # Identity, then discovery, then utility -- the librarians' own grouping.
    it 'runs the rows in the order the librarians settled on' do
      order = WorkDecorator::DISPLAY.pluck(:field)

      aggregate_failures do
        expect(order.index(:names)).to be < order.index(:publication_information)
        expect(order.index(:publication_information)).to be < order.index(:date_created)
        expect(order.index(:date_created)).to be < order.index(:genres)
        expect(order.index(:genres)).to be < order.index(:abstract)
        expect(order.index(:abstract)).to be < order.index(:subject_headings)
        expect(order.index(:subject_headings)).to be < order.index(:resource_type)
        expect(order.index(:resource_type)).to be < order.index(:extent)
        expect(order.index(:extent)).to be < order.index(:languages)
        expect(order.index(:languages)).to be < order.index(:host_collections)
        expect(order.index(:host_collections)).to be < order.index(:location)
        expect(order.index(:location)).to be < order.index(:identifiers)
        expect(order.index(:identifiers)).to be < order.index(:access_condition)
      end
    end
  end
end
