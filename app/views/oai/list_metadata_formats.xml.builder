# frozen_string_literal: true

# Both formats are available for every record, so the list does not vary by
# identifier. `mods` is the one Digital Commonwealth consumes; `oai_dc` is the
# protocol's mandatory minimum.
xml.ListMetadataFormats do
  OAI::FORMATS.each do |prefix, format|
    xml.metadataFormat do
      xml.metadataPrefix prefix
      xml.schema format[:schema]
      xml.metadataNamespace format[:namespace]
    end
  end
end
