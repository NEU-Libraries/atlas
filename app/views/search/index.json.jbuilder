# frozen_string_literal: true

json.results @results, partial: 'search/result', as: :result
json.pagination @pagination
