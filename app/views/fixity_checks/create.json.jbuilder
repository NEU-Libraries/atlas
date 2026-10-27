# frozen_string_literal: true

check = @check.to_h
json.fixity_check do
  json.resource_id @recorded[:resource].noid
  json.object check[:object]
  json.checked_at check[:checked_at]
  json.version check[:version]
  json.algorithm check[:algorithm]
  json.files check[:files]
  json.result check[:result]
  json.findings check[:findings]
  json.checker check[:checker]
  json.recorded_by check[:recorded_by]
  json.latest @recorded[:latest]
end
