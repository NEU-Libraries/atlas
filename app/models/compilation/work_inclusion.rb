# frozen_string_literal: true

class Compilation
  # "Include Work X individually" recipe line — union'd with the collection
  # inclusions at read time.
  class WorkInclusion < ApplicationRecord
    include Compilation::Membership

    EXPECTED_RESOURCE_TYPE = Work
  end
end
