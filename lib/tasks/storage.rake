# frozen_string_literal: true

namespace :atlas do
  namespace :storage do
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
