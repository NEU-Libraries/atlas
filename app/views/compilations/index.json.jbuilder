# frozen_string_literal: true

json.compilations do |root|
  root.array!(@compilations) do |compilation|
    json.partial! 'compilations/compilation', compilation: compilation
  end
end
json.pagination @pagination
