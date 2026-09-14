# frozen_string_literal: true

# Every displayed MODS field projects as { value:, display_label:, href: }, so
# a spec seeding a Metadata::MODS by hand cannot pass a bare string. These
# build the entries, keeping a spec that is about something else -- a Solr
# facet, a sort key -- readable.
module LabeledValueHelper
  # Labeled values from plain strings, for a spec that is not about the header.
  def labeled_values(*values, **attributes)
    values.flatten.map { |value| { value: value, **attributes } }
  end

  # One labeled value, for a single-entry field.
  def labeled_value(value, **attributes)
    { value: value, **attributes }
  end
end

RSpec.configure { |config| config.include LabeledValueHelper }
