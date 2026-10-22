# frozen_string_literal: true

json.status   @health[:status]
json.database @health[:database]
json.index    @health[:index]
json.storage  @health[:storage]
json.cache    @health[:cache]
