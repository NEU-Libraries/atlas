# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.ancestors @work.ancestors
  json.title @work.plain_title
  json.description @work.plain_description
end
