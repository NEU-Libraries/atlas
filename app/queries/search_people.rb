# frozen_string_literal: true

# Valkyrie custom query: the Persons matching a typeahead fragment, counted and
# paged in SQL so `GET /people?q=` paginates over the matches. See
# docs/people.md.
#
# A fragment matches a display_name by case-insensitive infix, a NUID by prefix,
# and the email of any account holding that NUID by case-insensitive infix.
class SearchPeople
  def self.queries
    %i[count_people_matching find_people_matching]
  end

  # Valkyrie array-wraps scalar attribute values in the jsonb, so the name is
  # the first element. Shared with User.directory_search, which joins Persons
  # under its own alias.
  def self.display_name_sql(table = 'orm_resources')
    "#{table}.metadata->'display_name'->>0"
  end

  def initialize(query_service:)
    @query_service = query_service
  end

  def count_people_matching(fragment:)
    matching(fragment).count
  end

  def find_people_matching(fragment:, limit:, offset: 0)
    matching(fragment)
      .order(Arel.sql("lower(#{self.class.display_name_sql}) ASC, orm_resources.id ASC"))
      .limit(limit)
      .offset(offset)
      .map { |object| @query_service.resource_factory.to_resource(object: object) }
  end

  private

    def matching(fragment)
      pattern = orm.sanitize_sql_like(fragment.to_s)
      nuid = "orm_resources.metadata->'nuid'->>0"
      orm.where(internal_resource: 'Person')
         .where("#{self.class.display_name_sql} ILIKE :infix OR #{nuid} LIKE :prefix OR " \
                "#{nuid} IN (SELECT users.nuid FROM users WHERE users.email ILIKE :infix)",
                infix: "%#{pattern}%", prefix: "#{pattern}%")
    end

    def orm
      Valkyrie::Persistence::Postgres::ORM::Resource
    end
end
