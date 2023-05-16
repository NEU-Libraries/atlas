# frozen_string_literal: true

module NoidHelper
  def resolve_id(pid)
    Resource.find(pid).id
  end
end
