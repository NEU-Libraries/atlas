# frozen_string_literal: true

class Compilation
  # "Set Work X aside" recipe line — subtracted from the resolved union at
  # read time. Excluding a Work that no inclusion currently covers is legal
  # (the recipe lines are independent; the subtraction just matches nothing).
  class Exclusion < ApplicationRecord
    include Compilation::Membership

    EXPECTED_RESOURCE_TYPE = Work
  end
end
