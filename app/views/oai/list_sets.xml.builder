# frozen_string_literal: true

# setSpec is the Compilation's NOID and setName its title. v1 stripped the
# `neu:` prefix off a Fedora pid here and glued it back on in the set filter;
# a NOID needs neither.
#
# setDescription is omitted when the Set has none. An empty <setDescription/>
# is schema-invalid — descriptionType requires exactly one foreign-namespace
# child — which is what v1 emitted.
xml.ListSets do
  @sets.each do |set|
    xml.tag!('set') do
      xml.setSpec set.noid
      xml.setName set.title
      next if set.description.blank?

      xml.setDescription do
        xml << render('oai/dublin_core', dc: { description: [set.description] })
      end
    end
  end
end
