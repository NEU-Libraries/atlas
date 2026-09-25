# frozen_string_literal: true

# Writes the diminutive and formal forms of each personal name a record holds,
# so a search for "Tim Smith" matches "Smith, Timothy". Match-only: the field
# is never displayed or faceted. See docs/solr-indexing.md#namevariantindexer.
class NameVariantIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    mods = resource.try(:mods)
    return {} if mods.nil?

    variants = candidate_names(mods).flat_map { |name| NameVariants.full_names(name) }.uniq
    variants.empty? ? {} : { name_variant_teim: variants }
  end

  private

    def candidate_names(mods)
      Array(mods.names).map(&:name) + subject_names(mods)
    end

    # Cerberus's IPTC ingest writes each person in a photo as a plain topic, so
    # the names a photo search most needs carry no name markup at all. A topic
    # counts only when it is one part and name-shaped.
    def subject_names(mods)
      Array(mods.subject_headings).filter_map do |heading|
        case heading.axis
        when 'personal_name' then heading.parts.first
        when 'topic' then heading.heading if heading.parts.one? && NameVariants.name_shaped?(heading.heading)
        end
      end
    end
end
