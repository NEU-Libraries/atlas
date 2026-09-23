# frozen_string_literal: true

# id, noid, klass, title and thumbnail are the find_many digest, so a client
# parses one shape across the Solr-backed lists.
json.id result[:noid]
json.extract! result, :noid, :klass, :title, :creators, :year, :thumbnail,
              :in_progress, :embargoed, :incomplete
