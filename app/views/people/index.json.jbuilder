# frozen_string_literal: true

json.people do |root|
  root.array!(@people) do |person|
    json.partial! 'people/person_fields', person: person
  end
end
json.pagination @pagination
