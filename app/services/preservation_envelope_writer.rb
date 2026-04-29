# frozen_string_literal: true

# Writes the resource's preservation envelope (relationships.json /
# properties.json + permissions.json) into the resource's own NOID-keyed
# OCFL object via Valkyrie's storage adapter. Idempotent at the SHA512
# level: an unchanged payload skips the content copy but does cut a new
# OCFL version with a fresh inventory.json (intentional — version churn
# is the audit trail).
class PreservationEnvelopeWriter < ApplicationService
  include FileHelper

  def initialize(resource:)
    @resource = resource
  end

  def call
    write(@resource.graph_payload, @resource.graph_filename)
    write(@resource.permissions_payload, 'permissions.json')
  rescue StandardError => e
    Rails.logger.error("envelope write failed for #{@resource.noid}: #{e.message}")
    raise
  end

  private

    def write(payload, filename)
      Tempfile.create([File.basename(filename, '.json'), '.json']) do |tmp|
        tmp.write(JSON.pretty_generate(payload))
        tmp.flush
        create_file(tmp.path, @resource, filename)
      end
    end
end
