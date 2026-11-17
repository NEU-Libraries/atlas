# frozen_string_literal: true

# Writes the resource's preservation envelope (relationships.json /
# properties.json + permissions.json) into the resource's own NOID-keyed
# OCFL object via Valkyrie's storage adapter.
#
# Two writes of one resource's envelope run one at a time, and each serializes
# the resource as it reads it under the lock, so a writer holding an older copy
# cannot store it last. A write whose bytes the head already holds writes
# nothing. See docs/write-safety.md.
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
    AdvisoryLock.hold('envelope', @resource.id) do
      current = reload
      Dir.mktmpdir { |dir| write(staged_in(dir, current), current) } if current
    end
  rescue StandardError => e
    Rails.logger.error("envelope write failed for #{@resource.noid}: #{e.message}")
    raise
  end

  private

    # nil once the resource is purged, because a write would recreate the
    # OCFL object the purge removed.
    def reload
      Atlas.query.find_by(id: @resource.id)
    rescue Valkyrie::Persistence::ObjectNotFoundError
      Rails.logger.warn("envelope write skipped for #{@resource.noid}: the resource no longer exists")
      nil
    end

    def write(entries, resource)
      create_files(entries, resource) unless unchanged?(entries, resource)
    end

    def unchanged?(entries, resource)
      adapter = Valkyrie.config.storage_adapter
      return false unless adapter.respond_to?(:head_digests)

      head = adapter.head_digests(key: resource.noid)
      entries.all? { |path, filename| head[filename] == Digest::SHA512.file(path).hexdigest }
    end

    def payloads(resource)
      { resource.graph_filename => resource.graph_payload,
        'permissions.json'      => resource.permissions_payload }
    end

    def staged_in(dir, resource)
      payloads(resource).map do |filename, payload|
        path = File.join(dir, filename)
        ::File.write(path, JSON.pretty_generate(payload))
        [path, filename]
      end
    end
end
