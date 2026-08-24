# frozen_string_literal: true

json.person do
  json.partial! 'people/person_fields', person: person
end
