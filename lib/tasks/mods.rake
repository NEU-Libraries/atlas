# frozen_string_literal: true

namespace :atlas do
  namespace :mods do
    desc 'Rebuild every JSON access copy from its MODS XML. Idempotent.'
    task reproject: :environment do
      # The XML is the preservation copy and the access copy is derived from
      # it, so a projection that changes shape -- a field that was a string
      # becoming an entry -- leaves stored rows that attr_json can no longer
      # cast. This rebuilds them from the source of truth. Run it after taking
      # a neu-mods version that reshapes a field.
      #
      # mods_json= rather than mods_xml=: the XML on disk is already right, and
      # writing it back would mint an OCFL version per resource for a change
      # that is not to the preservation copy.
      total  = 0
      errors = 0

      [Community, Collection, Work].each do |klass|
        Atlas.query.find_all_of_model(model: klass).each do |resource|
          next unless resource.mods_writable?

          # The stale row is deleted, not overwritten. mods_json= reads the row
          # before it writes -- to see whether a container's title moved -- and
          # reading is precisely what a row in the old shape cannot survive.
          # Starting from nothing is what a derived copy is entitled to.
          Metadata::MODS.where(valkyrie_id: resource.noid).delete_all
          resource.mods_json = resource.mods_xml
          total += 1
          Rails.logger.info "  mods reprojected: #{total}" if (total % 100).zero?
        rescue StandardError => e
          errors += 1
          Rails.logger.warn "  mods reprojection failed for #{klass.name} #{resource.noid}: #{e.message}"
        end
      end

      Rails.logger.info "atlas:mods:reproject complete — reprojected #{total}, #{errors} errors"
    end
  end
end
