# frozen_string_literal: true

json.works do |root|
  root.array!(@works) do |work|
    json.work do
      json.id work.noid
      json.title work.plain_title
      json.description work.plain_description
      json.in_progress work.in_progress
      json.incomplete work.incomplete
      json.incomplete_reason work.incomplete_reason
      json.handle work.handle
    end
  end
end
json.pagination @pagination
