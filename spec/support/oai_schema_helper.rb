# frozen_string_literal: true

# XSD validation for /oai responses.
#
# A JSON-schema $ref (the drift detector everywhere else in this suite) cannot
# help here: OAI-PMH is a separate protocol with its own XSD, and the payloads
# it embeds have theirs. Validating against the real schemas is much stronger,
# and it catches the class of defect that the v1 endpoint shipped for a decade
# — an empty <setDescription/>, which descriptionType rejects.
#
# The schemas are vendored under spec/fixtures/schemas with every remote
# schemaLocation rewritten to a local path, because Nokogiri validates with
# libxml2's NONET flag and would otherwise fail to resolve them.
module OAISchemaHelper
  SCHEMA_PATH = Rails.root.join('spec/fixtures/schemas/atlas-oai.xsd').freeze

  # mods-3-5.xsd alone is 50KB of schema; compile it once for the whole run.
  def self.schema
    @schema ||= Nokogiri::XML::Schema.from_document(
      Nokogiri::XML(File.read(SCHEMA_PATH), SCHEMA_PATH.to_s)
    )
  end

  def expect_valid_oai(body)
    errors = OAISchemaHelper.schema.validate(Nokogiri::XML(body))
    expect(errors).to be_empty,
                      -> { "response failed XSD validation:\n#{errors.map(&:message).join("\n")}\n\n#{body}" }
  end

  # Namespace-aware read of the response body — every OAI element sits in the
  # OAI-PMH namespace, so a bare xpath finds nothing.
  def oai_doc(body)
    Nokogiri::XML(body).tap(&:remove_namespaces!)
  end
end

RSpec.configure do |config|
  config.include OAISchemaHelper
end
