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

  # One version, not one per file. The graph and the permissions describe the
  # same instant and are always written together, so splitting them across two
  # versions records nothing the single version does not — both paths appear in
  # every version's state either way — while doubling the inventories, sidecars
  # and fsyncs the write costs.
  def call
    Dir.mktmpdir do |dir|
      create_files(staged_in(dir), @resource)
    end
  rescue StandardError => e
    Rails.logger.error("envelope write failed for #{@resource.noid}: #{e.message}")
    raise
  end

  private

    def payloads
      { @resource.graph_filename => @resource.graph_payload,
        'permissions.json'       => @resource.permissions_payload }
    end

    def staged_in(dir)
      payloads.map do |filename, payload|
        path = File.join(dir, filename)
        ::File.write(path, JSON.pretty_generate(payload))
        [path, filename]
      end
    end
end
