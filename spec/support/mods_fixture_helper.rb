# frozen_string_literal: true

# Test-only fixture affordance for populating a resource's descriptive MODS.
#
# Replaces the removed MODSAssignment#plain_title= / #plain_description= flat
# setters, which app code no longer provides: production descriptive merges
# belong to the caller (Cerberus / MODSMerge), and the only Atlas write path is
# the raw, caller-assembled `mods_xml=`. These helpers exist purely so specs can
# seed a known primary title / abstract through that same raw path; they are NOT
# an application API.
module MODSFixtureHelper
  def set_mods_primary_title!(resource, title)
    doc = Mods::Record.new.from_str(resource.mods_xml)
    doc.title_info.find { |n| n.attribute('usage')&.value == 'primary' }.title.content = title
    resource.mods_xml = doc.to_xml
  end

  def set_mods_abstract!(resource, abstract)
    doc = Mods::Record.new.from_str(resource.mods_xml)
    doc.abstract.first.content = abstract
    resource.mods_xml = doc.to_xml
  end
end

RSpec.configure do |config|
  config.include MODSFixtureHelper
end
