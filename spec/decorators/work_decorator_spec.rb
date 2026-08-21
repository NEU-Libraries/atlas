# frozen_string_literal: true

require 'rails_helper'

# The MODS HTML projection (works/mods.html.haml) is just a concatenation of
# these decorator methods, so asserting each method's output IS asserting the
# rendered HTML. Single-value fields must omit the whole field for blank values
# rather than emitting an empty <dd> under a label, matching how the multivalued
# loop_field branch behaves.
RSpec.describe WorkDecorator do
  # Decorate a bare Work whose #mods returns a controlled access copy, so the
  # gating is asserted directly without depending on the WorkCreator template.
  def decorate_with(**mods_attrs)
    mods = Metadata::MODS.new(**mods_attrs)
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }.decorate
  end

  context 'when the single-value fields are blank (a sparse record)' do
    subject(:work) { decorate_with }

    it 'omits the whole field (no label, no value) for each blank single-value field' do
      expect(work.date_created).to eq('')
      expect(work.resource_type).to eq('')
      expect(work.digital_origin).to eq('')
      expect(work.permanent_url).to eq('')
      expect(work.access_condition).to eq('')
      expect(work.abstract).to eq('')
    end
  end

  context 'when the single-value fields are populated (a described record)' do
    subject(:work) do
      decorate_with(
        date_created:     Time.zone.parse('2017-09-19'),
        resource_type:    'sound recording',
        digital_origin:   'born digital',
        permanent_url:    'http://hdl.handle.net/2047/D20254217',
        access_condition: 'Copyright restrictions may apply.',
        abstract:         'How communities respond to disaster.'
      )
    end

    it 'renders the label and value for each populated field' do
      expect(work.date_created).to eq('<dt>Date created</dt><dd>2017-09-19</dd>')
      expect(work.resource_type).to eq('<dt>Resource Type</dt><dd>Sound Recording</dd>')
      expect(work.digital_origin).to eq('<dt>Digital Origin</dt><dd>Born Digital</dd>')
      expect(work.abstract).to eq('<dt>Abstract</dt><dd><p>How communities respond to disaster.</p></dd>')
    end

    it 'linkifies the permanent_url and access_condition values' do
      expect(work.permanent_url).to eq(
        '<dt>Permanent URL</dt><dd><p>' \
        '<a href="http://hdl.handle.net/2047/D20254217" rel="nofollow noopener" ' \
        'target="_blank">http://hdl.handle.net/2047/D20254217</a></p></dd>'
      )
      expect(work.access_condition)
        .to eq('<dt>Use and reproduction</dt><dd><p>Copyright restrictions may apply.</p></dd>')
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
      work = decorate_with(
        main_title: Metadata::Fields::TitleInfo.new(title: 'H<sub>2</sub>O')
      )

      expect(work.plain_title).to eq('H<sub>2</sub>O')
    end
  end
end
