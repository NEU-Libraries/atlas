# frozen_string_literal: true

# The Darwin Core HTML block: one section per TDWG class, in the standard's
# order. Reads the JSON access copy only. See docs/metadata-records.md.
module DarwinCoreDecoration
  TERMS = DarwinCoreTerms::TERMS.to_h { |term, label, group| [term, { label: label, group: group }] }.freeze

  # A term outside the standard list still renders, so a record cannot hold a
  # value the display hides.
  OTHER_GROUP = { other: 'Other terms' }.freeze
  GROUPS = DarwinCoreTerms::GROUPS.merge(OTHER_GROUP).freeze

  # The standard's own recommendation for a list in one term is " | ".
  LIST_SEPARATOR = '|'

  def darwin_core_sections
    rows = darwin_core_rows
    safe_join(GROUPS.filter_map do |group, heading|
      entries = rows[group]
      next if entries.blank?

      tag.section(tag.h3(heading) + tag.dl(safe_join(entries)), class: 'dwc-group', data: { group: group })
    end)
  end

  private

    # Standard terms keep the standard's order; other terms sort by name,
    # because the jsonb access copy does not keep the document's order.
    def darwin_core_rows
      terms = darwin_core&.json_attributes || {}
      known, other = terms.keys.partition { |term| TERMS.key?(term) }
      ordered = TERMS.keys.intersection(known) + other.sort

      ordered.each_with_object(Hash.new { |h, k| h[k] = [] }) do |term, rows|
        group = TERMS.dig(term, :group) || :other
        rows[group] << darwin_core_row(term, darwin_core_values(terms[term]))
      end
    end

    # `data-term` is the stable hook a consumer overrides a label by: the
    # label text is TDWG's and can change with the standard.
    def darwin_core_row(term, values)
      return '' if values.empty?

      values.reduce(tag.dt(darwin_core_label(term), data: { term: term })) { |row, value| row + tag.dd(value) }
    end

    def darwin_core_label(term)
      TERMS.dig(term, :label) || term.underscore.humanize.titleize
    end

    def darwin_core_values(value)
      value.to_s.split(LIST_SEPARATOR).map(&:strip).compact_blank.map { |part| linkify(part) }
    end
end
