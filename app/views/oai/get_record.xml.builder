# frozen_string_literal: true

xml.GetRecord do
  xml << render('oai/record', record: @record, prefix: @oai.metadata_prefix)
end
