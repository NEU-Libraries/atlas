# frozen_string_literal: true

# "Include Work X individually" recipe line — union'd with the collection
# inclusions at read time.
class CompilationWorkInclusion < ApplicationRecord
  include CompilationMembership

  EXPECTED_RESOURCE_TYPE = Work
end
