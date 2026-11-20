# frozen_string_literal: true

# XSD validation for the METS Atlas writes. The schema is vendored with its
# XLink import pointed at the local copy, because Nokogiri validates with
# libxml2's NONET flag and cannot fetch it.
module METSSchemaHelper
  SCHEMA_PATH = Rails.root.join('spec/fixtures/schemas/mets-1-12-1.xsd').freeze

  def self.schema
    @schema ||= Nokogiri::XML::Schema.from_document(
      Nokogiri::XML(File.read(SCHEMA_PATH), SCHEMA_PATH.to_s)
    )
  end

  def expect_valid_mets(xml)
    errors = METSSchemaHelper.schema.validate(Nokogiri::XML(xml))
    expect(errors).to be_empty,
                      -> { "METS failed XSD validation:\n#{errors.map(&:message).join("\n")}\n\n#{xml}" }
  end
end

RSpec.configure do |config|
  config.include METSSchemaHelper
end
