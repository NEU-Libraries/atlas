# frozen_string_literal: true

json.works @works, partial: 'scoped_searches/work_digest', as: :digest
json.pagination @pagination
json.facets @facets
