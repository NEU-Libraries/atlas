# frozen_string_literal: true

# Test-only fixture affordance for populating a resource's descriptive MODS.
#
# App code provides no flat per-field MODS setters: production descriptive
# merges belong to the caller (Cerberus / MODSMerge), and the only Atlas write
# path is the raw, caller-assembled `mods_xml=`. These helpers exist purely so
# specs can seed a known primary title / abstract through that same raw path;
# they are NOT an application API.
module MODSFixtureHelper
  def set_mods_primary_title!(resource, title)
    doc = NEU::MODS::Document.parse(resource.mods_xml)
    doc.primary_title_info.at_xpath('mods:title', NEU::MODS::NAMESPACE).content = title
    resource.mods_xml = doc.to_xml
  end

  # Creates the <abstract> when the document has none, because the minted MODS
  # template seeds no empty placeholder elements — the same absence any
  # caller-assembled document can have, and the same branch MODSMerge takes.
  def set_mods_abstract!(resource, abstract)
    doc  = NEU::MODS::Document.parse(resource.mods_xml)
    node = doc.abstract_nodes.first
    if node
      node.content = abstract
    else
      doc.doc.at_xpath('/mods:mods', NEU::MODS::NAMESPACE)
         .add_child(doc.build_node('abstract', abstract))
    end
    resource.mods_xml = doc.to_xml
  end

  # Append <mods:genre> elements and reassign through the raw mods_xml= path, so
  # the genres flow through the real NEU::MODS projection into mods.genres (the
  # same chain GenreIndexer reads) rather than being poked onto the JSON record.
  def set_mods_genres!(resource, genres)
    doc  = NEU::MODS::Document.parse(resource.mods_xml)
    root = doc.doc.at_xpath('/mods:mods', NEU::MODS::NAMESPACE)
    Array(genres).each do |value|
      node = Nokogiri::XML::Node.new('genre', doc.doc)
      node.namespace = root.namespace
      node.content   = value
      root.add_child(node)
    end
    resource.mods_xml = doc.to_xml
  end
end

RSpec.configure do |config|
  config.include MODSFixtureHelper
end
