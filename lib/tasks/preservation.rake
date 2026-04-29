# frozen_string_literal: true

namespace :atlas do
  namespace :preservation do
    desc 'Backfill relationships.json / properties.json + permissions.json for every resource. Idempotent.'
    task backfill_envelopes: :environment do
      classes = [Community, Collection, Work, FileSet, Blob]
      total   = 0
      errors  = 0

      classes.each do |klass|
        Atlas.query.find_all_of_model(model: klass).each do |resource|
          resource.write_preservation_envelope!
          total += 1
          puts "  envelopes written: #{total}" if (total % 100).zero?
        rescue StandardError => e
          errors += 1
          warn "  envelope failed for #{klass.name} #{resource.noid}: #{e.message}"
        end
      end

      puts "atlas:preservation:backfill_envelopes complete — wrote #{total}, #{errors} errors"
    end
  end
end
