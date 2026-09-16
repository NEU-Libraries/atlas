# frozen_string_literal: true

module OAI
  # The oai_dc crosswalk: the JSON access copy projected onto the fifteen
  # simple Dublin Core elements. Off the JSON copy and NEVER off the XML -- a
  # Nokogiri parse per record on an access endpoint is what this project does
  # not do. Only creator-role names become dc:creator. See docs/oai.md.
  class DublinCore
    # Named rather than inlined because it is a FOURTH list that has to agree
    # with NEU::MODS::FIELDS and nothing made it -- a new axis passed every
    # spec and was silently absent. A spec derives it from the registry now.
    # hierarchical_geographic_subjects and subject_headings are excluded.
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

      # A role-less name harvests as a CREATOR here. It previously became a
      # contributor because "" never matched "creator", which silently demoted
      # every unroled name and a name roled `aut` with it.
      def creator
        names_with_role { |role| MarcRelators.creator?(role) }
      end

      def contributor
        names_with_role { |role| !MarcRelators.creator?(role) }
      end

      # Matches on ANY role, so a name recorded as both author and advisor
      # harvests as both -- which is what the record asserts.
      def names_with_role(&)
        Array(mods&.names).select { |n| roles_of(n).any?(&) }.map(&:name)
      end

      # Keeps a single nil on purpose: MarcRelators.creator? reads nil as a
      # creator. An EMPTY array matches neither branch and drops the name.
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

      # Day precision, because a DC consumer wants a date and the column is a
      # datetime. A ranged record ships the ISO 8601 interval (1935/1940) --
      # the start alone would assert a date the record never claimed. The
      # qualifier is dropped: simple DC cannot say "approximate".
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
        Array(mods&.resource_type).filter_map { |entry| entry.value.presence }
      end

      # The bare term: dc:language takes a code or a name and nothing else, so
      # the display's "Spanish (subtitles)" would match no vocabulary.
      def language
        Array(mods&.languages).filter_map { |entry| entry.term.presence }
      end

      # dc:identifier repeats, so a DOI ships beside the handle -- both
      # resolve. COLID and BDR_METSID stay out: they resolve nowhere outside
      # the repository that minted them.
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
