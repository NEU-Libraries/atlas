# frozen_string_literal: true

json.works do |root|
  root.array!(@works) do |work|
    json.work do
      json.id work.noid
      json.title work.plain_title
      json.description work.plain_description
    end
  end
end
json.pagination @pagination
