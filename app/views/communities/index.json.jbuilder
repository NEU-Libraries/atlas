# frozen_string_literal: true

json.communities do |root|
  root.array!(@communities) do |community|
    json.id community.noid
    json.title community.plain_title
    json.description community.plain_description
  end
end
json.pagination @pagination
