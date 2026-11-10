# frozen_string_literal: true

# The :test_solr adapter does not soft-commit on save, so this commits instead:
# once, before the first Solr read after a write. Every read still sees every
# write that finished before it. See docs/testing.md.
module LazySolrCommit
  MUTEX = Mutex.new

  class << self
    def wrote!
      MUTEX.synchronize { @pending = true }
    end

    # Clears the flag in the same step that reads it, so a write that finishes
    # while the commit is in flight sets it again rather than being lost.
    def take!
      MUTEX.synchronize { @pending.tap { @pending = false } }
    end

    def committing?
      Thread.current[:lazy_solr_committing]
    end

    def committing
      outer = Thread.current[:lazy_solr_committing]
      Thread.current[:lazy_solr_committing] = true
      yield
    ensure
      Thread.current[:lazy_solr_committing] = outer
    end

    def commits?(params)
      (params || {}).any? { |key, value| %w[commit softCommit].include?(key.to_s) && value.to_s == 'true' }
    end
  end

  module Client
    def commit(...)
      LazySolrCommit.committing { super }
    end

    # Marks the write only once Solr has taken it, so a read that commits in
    # between cannot clear the flag ahead of an add still on the wire.
    def execute(request_context)
      unless request_context[:path].to_s.start_with?('update')
        soft_commit if LazySolrCommit.take!
        return super
      end

      super.tap do
        LazySolrCommit.wrote! unless LazySolrCommit.committing? || LazySolrCommit.commits?(request_context[:params])
      end
    end
  end
end

RSolr::Client.prepend(LazySolrCommit::Client)
