# frozen_string_literal: true

class Compilation
  # "Include everything under Collection X" recipe line. Resolved transitively
  # at read time by CompilationContentsQuery (the collection itself plus its
  # ancestor_ids_ssim descendants).
  class CollectionInclusion < ApplicationRecord
    include Compilation::Membership

    EXPECTED_RESOURCE_TYPE = Collection
  end
end
