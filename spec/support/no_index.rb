# frozen_string_literal: true

# Spec files that never read Solr run on Postgres alone: no indexing on save,
# no soft commit, no footprint query. A service spec runs about twice as fast.
# spec/no_index_files.txt lists them, and bin/no-index-candidates adds every
# file a whole run saw read nothing. See docs/testing.md.
#
# The guard is what keeps the list honest: a listed example that reads Solr
# raises rather than passing on an empty index, so a search that should find
# nothing cannot pass because nothing was indexed.
module NoIndex
  LIST = Rails.root.join('spec/no_index_files.txt')

  class SolrRead < StandardError; end

  class << self
    attr_accessor :guarded, :wrote, :current_file, :persisting

    def listed = @listed ||= LIST.exist? ? LIST.readlines(chomp: true).reject { |l| l.blank? || l.start_with?('#') }.to_set : Set.new

    def ran = @ran ||= Set.new
    def read = @read ||= Set.new
    def failed = @failed ||= Set.new
    def tagged = @tagged ||= Set.new

    # An update is a save, a delete or a wipe; everything else asks Solr a
    # question, unless the Solr persister asks it while saving: it looks a
    # persisted resource up before writing it again.
    def request!(path)
      if persisting || path.to_s.start_with?('update')
        self.wrote = true
      elsif guarded
        raise SolrRead, "#{guarded} reads Solr (#{path.to_s.split('?').first}), so it cannot run without an index: " \
                        "remove #{relative(guarded)} from spec/no_index_files.txt"
      elsif current_file
        explain(path) if ENV['NO_INDEX_DEBUG']
        read << current_file
      end
    end

    # NO_INDEX_DEBUG=1 prints each read and the app frame that sent it.
    def explain(path)
      frame = caller.find { |line| line.include?('/app/') || line.include?('/lib/atlas') }
      warn "[no_index read] #{current_file} #{path.to_s.split('?').first} <- #{frame}"
    end

    def relative(path) = path.to_s.delete_prefix('./').sub(/:\d+\z/, '')

    # A partial run says nothing about the examples it left out, so only a run
    # of whole files, every one of which passed, proposes candidates. A file
    # that tags its own examples has chosen per example, so it is left alone.
    def write_candidates!(filter_manager)
      return unless filter_manager.inclusions.empty?

      candidates = (ran - read - failed - tagged - listed).sort
      Rails.root.join("tmp/no_index_candidates#{ENV.fetch('TEST_ENV_NUMBER', nil)}.txt").write(candidates.map { "#{it}\n" }.join)
    end
  end

  # Every request RSolr sends passes through here: Valkyrie's index adapter,
  # SystemHealth and RepositoryReset all use it.
  module Watch
    def execute(request_context)
      NoIndex.request!(request_context[:path])
      super
    end
  end
end

RSolr::Client.prepend(NoIndex::Watch)

# The reads the Solr persister makes inside a save belong to the save.
module NoIndex
  module Persisting
    %i[save save_all delete].each do |name|
      define_method(name) do |**options|
        outer = NoIndex.persisting
        NoIndex.persisting = true
        super(**options)
      ensure
        NoIndex.persisting = outer
      end
    end
  end
end

Valkyrie::Persistence::Solr::Persister.prepend(NoIndex::Persisting)

# The composite minus Solr, keeping the response-cache eviction every save makes.
Valkyrie::MetadataAdapter.register(
  Valkyrie::AdapterContainer.new(
    persister:     Valkyrie::Persistence::CacheEvictingPersister.new(Valkyrie::MetadataAdapter.find(:postgres).persister),
    query_service: Valkyrie::MetadataAdapter.find(:postgres).query_service
  ),
  :test_postgres_only
)

RSpec.configure do |config|
  config.define_derived_metadata do |meta|
    meta[:no_index] = true if NoIndex.listed.include?(NoIndex.relative(meta[:rerun_file_path] || meta[:file_path]))
  end

  # A before(:all) reads as its file too.
  config.before(:context) { NoIndex.current_file = NoIndex.relative(self.class.metadata[:rerun_file_path]) }
  config.after(:context) { NoIndex.current_file = nil }

  config.around do |example|
    file = NoIndex.relative(example.metadata[:rerun_file_path])
    NoIndex.current_file = file
    if example.metadata[:no_index]
      NoIndex.tagged << file unless NoIndex.listed.include?(file)
      begin
        NoIndex.guarded = example.location
        NoIndex.wrote = false
        Valkyrie.config.metadata_adapter = :test_postgres_only
        example.run
      ensure
        Valkyrie.config.metadata_adapter = :test_composite_persister
        NoIndex.guarded = nil
        # An explicit reindex still writes; a later example's search must not find it.
        Atlas.index_adapter.persister.wipe! if NoIndex.wrote
      end
    else
      NoIndex.ran << file
      example.run
      NoIndex.failed << file if example.exception
    end
  end

  config.after(:suite) { NoIndex.write_candidates!(config.filter_manager) }
end
