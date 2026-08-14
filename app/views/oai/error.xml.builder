# frozen_string_literal: true

# OAI-PMH allows several <error> elements in one response, and OAI::Request
# accumulates rather than short-circuits, so a harvester debugging a malformed
# query sees everything wrong with it at once.
@oai.errors.each do |error|
  xml.error(error.message, code: error.code)
end
