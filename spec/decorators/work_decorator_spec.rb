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
end
