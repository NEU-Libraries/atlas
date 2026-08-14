# frozen_string_literal: true

# A nil value renders an empty element, which is how a harvester learns the
# list ended. cursor and completeListSize let it show progress; no
# expirationDate, because the token is stateless and signed rather than a row
# in a cursor table, so it never goes stale.
xml.resumptionToken(token.value,
                    completeListSize: token.complete_list_size,
                    cursor:           token.cursor)
