# frozen_string_literal: true

json.array! @communities do |community|
  json.community do
    json.id community.noid
    json.title community.plain_title
    json.description community.plain_description
  end
end
