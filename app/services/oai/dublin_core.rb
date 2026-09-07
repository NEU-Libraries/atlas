# frozen_string_literal: true

module OAI
  # The oai_dc crosswalk: Metadata::MODS (the JSON access copy) projected onto
  # the fifteen simple Dublin Core elements.
  #
  # Deliberately off the JSON copy and never off the XML. Reading MODS XML per
  # record would put a Nokogiri parse on an access endpoint, which this project
  # does not do; the JSON row exists precisely so a projection like this is a
  # cheap read. Solr cannot supply it either: the index carries the fields
  # discovery needs, not the fifteen this crosswalk wants, and reassembling a
  # record from facet fields would be a second projection to keep in step. So
  # the caller batches the rows with one Metadata::MODS.where(valkyrie_id:
  # noids) per page.
  #
  # It is a minimum-viable projection. MODS is the format Boston Public
  # Library consumes; oai_dc exists because OAI-PMH requires every repository
  # to support it. Two deliberate choices inside that:
  #
  #   - dc:type is populated. v1's always came out empty, because the `oai`
  #     gem skips a field called `type` to avoid Ruby's deprecated
  #     Object#type.
  #   - Only creator-role names become dc:creator; every other role becomes
  #     dc:contributor. Flattening a thesis advisor into dc:creator would put
  #     wrong attribution into a downstream catalogue. MarcRelators.creator?
  #     decides, so the code `aut`, the term `Author` and an absent role all
  #     land where the display and the creator facet already put them.
  class DublinCore
    # Every projected subject axis. Simple Dublin Core has one dc:subject and no
    # way to say which kind, so they all flatten into it.
    #
    # Named rather than inlined because this is a fourth list that has to agree
    # with NEU::MODS::FIELDS and nothing made it: a new axis passed every spec
    # and was silently absent from oai_dc. A spec derives this from the
    # registry now, which is the same guard DISPLAY and SOLR_FIELDS have.
    #
    # hierarchical_geographic_subjects is excluded deliberately: its members are
    # structured, and flattening a hash into dc:subject would emit an object
    # where a harvester expects a string. Its narrowest level is already in
    # geographic terms through the Solr index; a dc:subject rendering of it is
    # a composition decision, not a list membership one.
    # subject_headings is excluded for the opposite reason to the display: a
    # harvester wants discrete terms it can match, not one composed string, and
    # every part of a heading is already here through its own axis.
    SUBJECT_AXES = %i[topical_subjects personal_name_subjects corporate_name_subjects
                      temporal_subjects geographic_subjects genre_subjects
                      occupation_subjects geographic_code_subjects title_subjects].freeze

    # Emission order is free — oai_dc.xsd is an unbounded choice — but a fixed
    # order keeps responses diffable.
    ELEMENTS = %i[title creator contributor subject description
                  date type language identifier rights].freeze

    def self.call(mods)
      new(mods).call
    end

    def initialize(mods)
      @mods = mods
    end

    # element => [value, ...], with empty elements dropped so no <dc:type/>
    # ships with nothing in it.
    def call
      ELEMENTS.index_with { |element| Array(send(element)).compact_blank.uniq }
              .reject { |_element, values| values.empty? }
    end

    private

      attr_reader :mods

      # The primary title, assembled the way a citation reads it: non-sort
      # article, title, subtitle, then the part designation.
      def title
        info = mods&.main_title
        return [] if info.nil?

        main = [info.non_sort, info.title].compact_blank.join(' ')
        main = "#{main}: #{info.subtitle}" if info.subtitle.present?
        part = [info.part_number, info.part_name].compact_blank.join(', ')
        [part.present? ? "#{main}. #{part}" : main]
      end

      # A role-less name harvested as dc:contributor, because "" never matched
      # "creator". MODS makes mods:role optional, so that silently demoted
      # every name a record did not bother to role -- and a name roled `aut`
      # with it.
      def creator
        names_with_role { |role| MarcRelators.creator?(role) }
      end

      def contributor
        names_with_role { |role| !MarcRelators.creator?(role) }
      end

      # A name matches on any of its roles, so one recorded as both author and
      # thesis advisor harvests as both dc:creator and dc:contributor -- which
      # is what the record asserts, and what the display shows.
      def names_with_role
        Array(mods&.names).select { |n| roles_of(n).any? { |role| yield(role) } }.map(&:name)
      end

      # A role-less name keeps the single nil this crosswalk was written around:
      # MarcRelators.creator? reads nil as a creator, matching the display. An
      # empty array would match neither branch and drop the name entirely.
      def roles_of(name)
        Array(name.roles).presence || [nil]
      end

      # All five MODS subject axes flatten into dc:subject — simple Dublin
      # Core has one subject element and no way to say which kind.
      def subject
        SUBJECT_AXES.flat_map { |field| Array(mods&.public_send(field)) }
      end

      def description
        [mods&.abstract]
      end

      # Publication date first, falling back to creation. Day precision: the
      # underlying column is a datetime, but a DC consumer wants a date. A
      # ranged record ships the whole span as the ISO 8601 interval 1935/1940,
      # the form DCMI names for dc:date; emitting the start alone would assert a
      # single date the record never claimed. The qualifier is dropped on
      # purpose, because simple Dublin Core cannot say "approximate".
      def date
        start, finish = mods&.date_issued.present? ? issued_range : created_range
        return [] if start.blank?

        [[start, finish].compact_blank.map { |value| value.to_date.iso8601 }.join('/')]
      end

      def issued_range  = [mods.date_issued, mods.date_issued_end]
      def created_range = [mods&.date_created, mods&.date_created_end]

      # typeOfResource repeats in MODS, so this is already a list. Wrapping it
      # in another array would ship a stringified array into dc:type.
      def type
        Array(mods&.resource_type)
      end

      # The term alone, part-qualified or not. dc:language takes a language
      # code or name and nothing else, so the display's "Spanish (subtitles)"
      # is not a value to ship; a harvester that read it would have a string
      # matching no vocabulary. The Solr facet makes the same call for the same
      # reason -- one language, one value.
      def language
        Array(mods&.languages).filter_map { |entry| entry.term.presence }
      end

      # dc:identifier repeats, so a DOI ships beside the handle: both are
      # citable and both resolve for anyone who harvests them. The local
      # accession types -- COLID, BDR_METSID -- stay out, because they resolve
      # nowhere outside the repository that minted them and a harvester can only
      # discard them.
      def identifier
        [mods&.permanent_url, *dois]
      end

      def dois
        Array(mods&.identifiers).filter_map { |entry| entry.value if entry.type&.casecmp?('doi') }
      end

      def rights
        [mods&.access_condition]
      end
  end
end
