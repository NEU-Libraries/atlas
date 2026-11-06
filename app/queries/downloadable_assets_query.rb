# frozen_string_literal: true

# The downloadable assets of one Work, each beside the FileSet it is listed
# under: the read behind GET /works/:id/assets and the download roll-up on the
# Work's Solr doc. Both call this, so "downloadable" means one thing.
class DownloadableAssetsQuery
  def self.call(work:, tombstoned: false)
    new(work: work, tombstoned: tombstoned).call
  end

  def initialize(work:, tombstoned:)
    @work       = work
    @tombstoned = tombstoned
  end

  # @return [Array<Array(Valkyrie::Resource, FileSet)>] [asset, file_set] pairs,
  #   in FileSet order.
  def call
    file_sets = @work.children.reject { |fs| Classification.metadata?(fs.type) }
                     .select { |fs| fs.tombstoned.present? == @tombstoned }
    members   = Atlas.query.custom_queries.find_many_ordered_members(resources: file_sets)

    file_sets.flat_map do |fs|
      members.fetch(fs.id.to_s, [])
             .select { |m| Role.downloadable?(m.use) }
             .map    { |m| [m, fs] }
    end
  end
end
