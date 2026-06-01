# frozen_string_literal: true

namespace :atlas do
  namespace :ancestry do
    desc 'Backfill ancestor_ids_ssim on every Collection + Community Solr doc. Idempotent.'
    task backfill: :environment do
      # Collections + Communities only — Works never carry ancestor_ids_ssim
      # (see AncestryIndexer). Solr-only re-projection via Atlas.index_adapter
      # so we don't rewrite Postgres or bump optimistic-lock tokens.
      classes = [Community, Collection]
      total   = 0
      errors  = 0

      classes.each do |klass|
        Atlas.query.find_all_of_model(model: klass).each do |resource|
          Atlas.index_adapter.persister.save(resource: resource)
          total += 1
          Rails.logger.info "  ancestry reindexed: #{total}" if (total % 100).zero?
        rescue StandardError => e
          errors += 1
          Rails.logger.warn "  ancestry reindex failed for #{klass.name} #{resource.noid}: #{e.message}"
        end
      end

      Rails.logger.info "atlas:ancestry:backfill complete — reindexed #{total}, #{errors} errors"
    end
  end
end
