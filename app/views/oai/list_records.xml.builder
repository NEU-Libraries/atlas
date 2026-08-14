# frozen_string_literal: true

xml.ListRecords do
  @records.each { |record| xml << render('oai/record', record: record, prefix: @oai.metadata_prefix) }
  xml << render('oai/resumption_token', token: @token) if @token
end
