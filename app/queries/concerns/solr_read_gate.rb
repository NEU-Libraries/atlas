# frozen_string_literal: true

# The per-document read gate for a Solr query, as one fq. It admits what
# Ability#resource_readable? admits — public, a read group, an edit group, an
# edit user, the depositor — because edit implies read, and every creator adds
# the staff group as an edit group only. See docs/search.md.
module SolrReadGate
  extend ActiveSupport::Concern

  private

    # nil means ungated. Only :admin is exempt. :system can read any single
    # resource through Ability, but a list read as :system is not scoped to a
    # person, so exempting it would hand private Works to whatever it feeds.
    def read_gate_fq(user)
      return nil if user&.admin?

      groups  = Array(user&.groups).map { |g| quoted(g) }
      clauses = ["read_access_group_ssim:(#{([quoted('public')] + groups).uniq.join(' OR ')})"]
      clauses << "edit_access_group_ssim:(#{groups.join(' OR ')})" if groups.any?
      clauses.concat(person_clauses(user&.nuid))
      clauses.map { |c| "(#{c})" }.join(' OR ')
    end

    def person_clauses(nuid)
      return [] if nuid.blank?

      ["edit_access_person_ssim:#{quoted(nuid)}", "depositor_ssi:#{quoted(nuid)}"]
    end

    # A phrase, not RSolr.solr_escape: that leaves spaces bare, so a group
    # named "a OR b" would become two clauses.
    def quoted(value)
      %("#{value.to_s.gsub(/["\\]/) { |c| "\\#{c}" }}")
    end
end
