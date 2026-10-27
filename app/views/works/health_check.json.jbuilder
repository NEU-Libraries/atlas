# frozen_string_literal: true

json.noid @report[:noid]
json.grade @report[:grade]
# Always false over HTTP, so a client never reads a green as "the bytes were
# verified".
json.fixity_checked false
# The checks an external checker recorded (POST /fixity_checks), not a re-hash.
json.fixity do
  json.last_checked_at @report[:fixity][:last_checked_at]
  json.result @report[:fixity][:result]
  json.objects @report[:fixity][:objects]
  json.never_checked @report[:fixity][:never_checked]
end
json.findings @report[:findings] do |finding|
  json.severity finding[:severity]
  json.code finding[:code]
  json.subject finding[:subject]
  json.message finding[:message]
end
