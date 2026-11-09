# frozen_string_literal: true

json.resource do
  json.merge! GuestRedaction.permissions(@current_user, @resource.permissions)
end
