# frozen_string_literal: true

# "Include everything under Collection X" recipe line. Resolved transitively
# at read time by CompilationContentsQuery (the collection itself plus its
# ancestor_ids_ssim descendants).
class CompilationCollectionInclusion < ApplicationRecord
  include CompilationMembership

  EXPECTED_RESOURCE_TYPE = Collection
end
