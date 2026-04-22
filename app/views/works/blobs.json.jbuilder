# frozen_string_literal: true

json.array! @file_sets.flat_map(&:files) do |file|
  json.extract! file, :noid, :mime_type, :original_filename, Label.find(:label).name, :size
end
