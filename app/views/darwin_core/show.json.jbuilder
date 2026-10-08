# frozen_string_literal: true

json.work do
  json.id @work.noid
  json.dwc @work.darwin_core.json_attributes
end
