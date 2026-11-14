# frozen_string_literal: true

# A Work digest: find_many's vocabulary plus the citation facts a search row
# carries. compilations/contents, resources/descendant_works and the scoped
# search routes all render it.
json.id digest[:noid]
json.noid digest[:noid]
json.klass digest[:klass]
json.title digest[:title]
json.thumbnail digest[:thumbnail]
json.creators digest[:creators]
json.year digest[:year]
json.embargoed digest[:embargoed]
