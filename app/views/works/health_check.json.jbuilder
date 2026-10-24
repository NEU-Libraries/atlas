# frozen_string_literal: true

json.noid @report[:noid]
json.grade @report[:grade]
# Always false over HTTP, so a client never reads a green as "the bytes were
# verified".
json.fixity_checked false
json.findings @report[:findings] do |finding|
  json.severity finding[:severity]
  json.code finding[:code]
  json.subject finding[:subject]
  json.message finding[:message]
end
