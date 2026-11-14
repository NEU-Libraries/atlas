# frozen_string_literal: true

# Tombstoned works are filtered out by the query, so no flag is carried here.
json.works @works, partial: 'scoped_searches/work_digest', as: :digest
json.pagination @pagination
