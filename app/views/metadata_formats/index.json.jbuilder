# frozen_string_literal: true

json.array! @formats do |format|
  json.id         format.token
  json.label      format.label
  json.media_type format.media_type
end
