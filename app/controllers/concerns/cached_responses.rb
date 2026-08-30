# frozen_string_literal: true

# Serves a cached rendered body for the read actions whose output is a pure
# function of one resource's state.
#
# The shape is deliberate: the action resolves its record and calls
# `authorize!` FIRST, then wraps only the render. A cached body is therefore
# never handed to a caller the current ACL refuses, and the cache cannot
# become an authorization bypass the way an outermost Rack layer would — that
# layer never reaches Ability at all.
#
#   def show
#     work = find_work(params[:id])
#     authorize! :read, work || Work
#     return head(:not_found) if work.nil?
#
#     cached_render('works.show', work) do
#       @work = work.decorate
#       render :show, status: (@work.tombstoned ? :gone : :ok)
#     end
#   end
#
# Misses are not cached. An unknown NOID never reaches here (the action 404s
# above), and a body is only stored when the action actually rendered one.
module CachedResponses
  extend ActiveSupport::Concern

  # 410 is as stable as 200 — a tombstoned resource keeps answering `gone`
  # with the same body until something writes to it, and that write evicts.
  CACHEABLE_STATUSES = [200, 410].freeze

  private

    # @param scope [String] one of ResponseCache::SCOPES, format included
    # @param resource [Resource] the already-resolved, already-authorized record
    # @param audience [Symbol] :any, or :guest / :authenticated for a body that
    #   differs between the two (see ResponseCache::AUDIENCES)
    def cached_render(scope, resource, audience: :any)
      return yield if scope.nil?

      noid = resource.noid

      if (hit = ResponseCache.read(scope: scope, noid: noid, audience: audience))
        response.headers['X-Atlas-Cache'] = 'hit'
        render body: hit.body, status: hit.status, content_type: hit.content_type
        return
      end

      yield
      response.headers['X-Atlas-Cache'] = 'miss'
      return unless CACHEABLE_STATUSES.include?(response.status)

      ResponseCache.write(scope: scope, noid: noid, audience: audience,
                          status: response.status, body: response.body,
                          content_type: response.media_type)
    end

    # The one axis any cached view varies on: works/_asset.json.jbuilder
    # withholds the `permission` group list from guests so public traffic is
    # never told a Grouper group's name. Mirror that expression exactly — if
    # the view's condition changes, this must change with it, and the paired
    # spec asserts the two buckets stay distinct.
    def asset_audience
      @current_user && !@current_user.guest? ? :authenticated : :guest
    end

    # The format-qualified scope for an action that answers several, or nil for
    # a format nobody enumerated — cached_render then renders without caching.
    # A nil here is a runtime input we do not control (the request's format); a
    # scope string that is simply wrong is programmer error and still raises in
    # ResponseCache.key.
    def format_scope(base)
      scope = "#{base}.#{request.format.symbol}"
      ResponseCache::SCOPES.include?(scope) ? scope : nil
    end
end
