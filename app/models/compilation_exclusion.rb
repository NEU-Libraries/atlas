# frozen_string_literal: true

# "Set Work X aside" recipe line — subtracted from the resolved union at
# read time. Excluding a Work that no inclusion currently covers is legal
# (the recipe lines are independent; the subtraction just matches nothing).
class CompilationExclusion < ApplicationRecord
  include CompilationMembership

  EXPECTED_RESOURCE_TYPE = Work
end
