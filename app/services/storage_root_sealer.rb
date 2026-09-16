# frozen_string_literal: true

# Decides whether a storage root is full, and seals it if so. The adapter
# deliberately never measures a root -- it reads a seal marker and obeys it, so
# the write path costs one existence check. See docs/binaries.md.
#
# Counts OBJECTS and not bytes: an object count is three levels of readdir
# under the tuple layout, while a byte total needs a full recursive walk -- and
# a root worth sealing is exactly the one that walk is too expensive for.
class StorageRootSealer < ApplicationService
  # An object is one Atlas resource (a single-file Work is six), and averages
  # about thirteen stored files, so two million objects is roughly twenty-six
  # million files. Raise it against a key budget, not by feel.
  DEFAULT_MAX_OBJECTS = 2_000_000

  def initialize(root_name:,
                 max_objects: DEFAULT_MAX_OBJECTS,
                 force: false,
                 adapter: Valkyrie.config.storage_adapter)
    @root_name = root_name.to_s
    @max_objects = max_objects
    @force = force
    @adapter = adapter
  end

  def call
    return report(sealed: true, reason: 'already sealed') if adapter.sealed?(root_name)

    count = object_count
    return report(sealed: false, objects: count) if count < max_objects
    return report(sealed: false, objects: count, reason: LAST_ROOT_REFUSAL) if refuse_last_root?

    adapter.seal!(root_name, reason: "#{count} objects reached the limit of #{max_objects}")
    report(sealed: true, objects: count)
  end

  LAST_ROOT_REFUSAL = 'refused: sealing the only open root would stop every new deposit'

  private

    attr_reader :root_name, :max_objects, :force, :adapter

    # Sealing the last open root leaves the pool with nowhere to put a new
    # object, so every deposit raises. A scheduled task must not do that by
    # accident; an operator who means it passes force.
    def refuse_last_root?
      return false if force

      adapter.storage_roots.keys.count { |name| !adapter.sealed?(name) } <= 1
    end

    # Counts object roots by their NAMASTE marker rather than by directory
    # shape, so the storage root's own extensions directory is never mistaken
    # for content. Depth follows the configured layout.
    def object_count
      root = adapter.storage_roots.fetch(root_name)
      tuples = Array.new(root.number_of_tuples) { '*' }
      Dir.glob(root.base_path.join(*tuples, '*', Valkyrie::Storage::OCFL::OBJECT_NAMASTE).to_s).size
    end

    def report(sealed:, objects: nil, reason: nil)
      { root: root_name, objects: objects, max_objects: max_objects, sealed: sealed, reason: reason }
    end
end
