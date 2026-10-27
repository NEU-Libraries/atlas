# frozen_string_literal: true

namespace :atlas do
  namespace :fixity do
    desc 'Recompute each object\'s latest fixity check from its logs/fixity.jsonl. Idempotent.'
    task rebuild: :environment do
      report = FixityResultRebuilder.call
      Rails.logger.info "atlas:fixity:rebuild complete — #{report[:logged]} objects logged, " \
                        "#{report[:corrected]} corrected, #{report[:removed]} stale rows removed, " \
                        "#{report[:unreadable_lines]} unreadable lines skipped"
    end
  end
end
