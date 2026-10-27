# frozen_string_literal: true

namespace :atlas do
  namespace :fixity do
    desc 'Create the :fixity_checker fixture the rolling checker authenticates as. Idempotent.'
    task checker_user: :environment do
      user = User.find_or_create_by!(nuid: User::FIXITY_CHECKER_NUID) do |created|
        created.assign_attributes(name: 'User, Fixity Checker', email: 'fixity-checker@northeastern.edu',
                                  password: Devise.friendly_token[0, 20], role: :fixity_checker)
      end
      abort "#{user.nuid} exists with role #{user.role}, not fixity_checker" unless user.fixity_checker?

      Rails.logger.info "atlas:fixity:checker_user — #{user.nuid} is the :fixity_checker fixture"
    end

    desc 'Recompute each object\'s latest fixity check from its logs/fixity.jsonl. Idempotent.'
    task rebuild: :environment do
      report = FixityResultRebuilder.call
      Rails.logger.info "atlas:fixity:rebuild complete — #{report[:logged]} objects logged, " \
                        "#{report[:corrected]} corrected, #{report[:removed]} stale rows removed, " \
                        "#{report[:unreadable_lines]} unreadable lines skipped"
    end
  end
end
