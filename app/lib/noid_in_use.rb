# frozen_string_literal: true

# Noid::Rails' identifier_in_use hook: true for a NOID whose OCFL object already
# exists, so the minter draws another instead of handing out an id that would
# append a new resource's versions to someone else's object. Also true for a
# purged NOID, whose handle and citations must never lead to new material. See
# docs/resource-graph.md.
class NoidInUse
  def self.call(noid)
    if PurgedIdentifier.exists?(noid: noid)
      Rails.logger.warn("NOID #{noid} was purged; minting another. The minter state may have been rewound.")
      return true
    end

    adapter = Valkyrie.config.storage_adapter
    return false unless adapter.respond_to?(:object_exists?) && adapter.object_exists?(key: noid)

    # One line per NOID passed over, so a rewound minter shows in the logs.
    Rails.logger.warn("NOID #{noid} already has an OCFL object; minting another. " \
                      'The minter state may have been rewound.')
    true
  end
end
