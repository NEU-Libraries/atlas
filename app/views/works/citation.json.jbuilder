# frozen_string_literal: true

# CSL-JSON (Citation Style Language), so a reference manager or a formatter
# reads it as it is. An absent fact is left out rather than sent as null,
# which CSL processors do not expect. See docs/citation.md.
json.id @work.noid
json.type @citation.csl_type
json.title @citation.title
json.author(@citation.creators.map { |name| { literal: name } }) if @citation.creators.any?
json.contributor(@citation.contributors.map { |name| { literal: name } }) if @citation.contributors.any?
json.issued @citation.issued if @citation.issued
json.abstract @citation.abstract if @citation.abstract
json.keyword @citation.keywords.join(', ') if @citation.keywords.any?
json.URL @citation.url if @citation.url
