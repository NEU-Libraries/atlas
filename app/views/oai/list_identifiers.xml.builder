# frozen_string_literal: true

xml.ListIdentifiers do
  @records.each { |record| xml << render('oai/header', record: record) }
  xml << render('oai/resumption_token', token: @token) if @token
end
