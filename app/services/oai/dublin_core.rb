# frozen_string_literal: true

module OAI
  # The oai_dc crosswalk: Metadata::MODS (the JSON access copy) projected onto
  # the fifteen simple Dublin Core elements.
  #
  # Deliberately off the JSON copy and never off the XML. Reading MODS XML per
  # record would put a Nokogiri parse on an access endpoint, which this project
  # does not do; the JSON row exists precisely so a projection like this is a
  # cheap read. Solr cannot supply it either — resource_type reaches no
  # indexer, and only topical_subjects is projected (as keyword_ssim) — so the
  # caller batches the rows with one Metadata::MODS.where(valkyrie_id: noids)
  # per page.
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
  #     wrong attribution into a downstream catalogue. The role test matches
  #     CitationIndexer::CREATOR_ROLE.
  class DublinCore
    CREATOR_ROLE = 'creator'

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

      def creator
        names_with_role { |role| role.casecmp?(CREATOR_ROLE) }
      end

      def contributor
        names_with_role { |role| !role.casecmp?(CREATOR_ROLE) }
      end

      def names_with_role
        Array(mods&.names).select { |n| yield(n.role.to_s) }.map(&:name)
      end

      # All five MODS subject axes flatten into dc:subject — simple Dublin
      # Core has one subject element and no way to say which kind.
      def subject
        %i[topical_subjects personal_name_subjects corporate_name_subjects
           temporal_subjects geographic_subjects].flat_map { |field| Array(mods&.public_send(field)) }
      end

      def description
        [mods&.abstract]
      end

      # Publication date first, falling back to creation. Day precision: the
      # underlying column is a datetime, but a DC consumer wants a date.
      def date
        [(mods&.date_issued || mods&.date_created)&.to_date&.iso8601]
      end

      # typeOfResource repeats in MODS, so this is already a list. Wrapping it
      # in another array would ship a stringified array into dc:type.
      def type
        Array(mods&.resource_type)
      end

      def language
        Array(mods&.languages)
      end

      def identifier
        [mods&.permanent_url]
      end

      def rights
        [mods&.access_condition]
      end
  end
end
