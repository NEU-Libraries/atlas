require 'pagy/extras/metadata'

Pagy::DEFAULT[:items] = 10

# A page past the end is an empty page, as on the search-backed lists, not a
# raised Pagy::OverflowError.
require 'pagy/extras/overflow'
Pagy::DEFAULT[:overflow] = :empty_page
