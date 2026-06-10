# frozen_string_literal: true

json.array! @users do |user|
  json.partial! 'users/directory_entry', user: user
end
