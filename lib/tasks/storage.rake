# frozen_string_literal: true

namespace :atlas do
  namespace :storage do
    desc 'Check a candidate can host an OCFL storage root. PATH_TO_CHECK=/mnt/x, else every configured root.'
    task check_substrate: :environment do
      candidates = ENV['PATH_TO_CHECK'].presence&.split(',')
      if candidates.nil?
        # A configured root is created on first write, so an absent one is normal
        # here and creating it is what the adapter itself does. A path given by
        # hand is left alone: an absent mount is the answer, not something to fix.
        candidates = Valkyrie.config.storage_adapter.storage_roots.values.map(&:base_path)
        candidates.each { |root| FileUtils.mkdir_p(root) }
      end
      paths = candidates.map(&:to_s)
      failed = []

      paths.each do |candidate|
        report = SubstrateConformance.call(path: candidate)
        puts "#{report[:path]} — #{report[:ok] ? 'USABLE' : 'NOT USABLE'}"
        report[:checks].each do |check|
          state = if !check.required
                    'n/a '
                  elsif check.ok
                    'pass'
                  else
                    'FAIL'
                  end
          puts format('  %<id>d %<state>s  %<name>-38s %<detail>s',
                      id: check.id, state: state, name: check.name, detail: check.detail)
        end
        failed << report[:path] unless report[:ok]
      end

      abort "not usable: #{failed.join(', ')}" if failed.any?
    end

    desc 'Count the objects in each storage root and seal any that reached its limit. Idempotent.'
    task seal_full_roots: :environment do
      adapter = Valkyrie.config.storage_adapter
      names   = ENV['ROOT'].presence&.split(',') || adapter.storage_roots.keys
      limit   = ENV.fetch('MAX_OBJECTS', StorageRootSealer::DEFAULT_MAX_OBJECTS).to_i

      names.each do |name|
        report = StorageRootSealer.call(root_name: name, max_objects: limit,
                                        force: ENV['FORCE'].present?)
        Rails.logger.info "  #{report[:root]}: #{report[:objects] || '-'}/#{report[:max_objects]} " \
                          "objects, sealed=#{report[:sealed]}#{" (#{report[:reason]})" if report[:reason]}"
      end

      Rails.logger.info "atlas:storage:seal_full_roots complete — open root is now #{adapter.open_root_name}"
    rescue Valkyrie::Storage::OCFL::PoolSealed => e
      Rails.logger.warn "atlas:storage:seal_full_roots — #{e.message}; add a root before the next deposit"
    end
  end
end
