# frozen_string_literal: true

# Serves a cached rendered body for read actions. See
# docs/read-performance.md.
#
# THE SHAPE IS THE POINT: the action calls authorize! FIRST and wraps only the
# render, so a cached body is never handed to a caller the current ACL
# refuses. An outermost Rack layer would be an authorization bypass -- it
# never reaches Ability at all.
module CachedResponses
  extend ActiveSupport::Concern

  # 410 is as stable as 200: a tombstone answers `gone` until a write evicts.
  CACHEABLE_STATUSES = [200, 410].freeze

  private

    # `resource` must be already resolved AND already authorized.
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

    # Mirrors works/_asset.json.jbuilder, which withholds the `permission`
    # group list from guests so public traffic is never told a Grouper group's
    # name. IF THE VIEW'S CONDITION CHANGES, THIS MUST CHANGE WITH IT.
    def asset_audience
      @current_user && !@current_user.guest? ? :authenticated : :guest
    end

    # nil for a format nobody enumerated, which renders without caching: the
    # request's format is a runtime input. A scope string that is simply wrong
    # is programmer error and still raises in ResponseCache.key.
    def format_scope(base)
      scope = "#{base}.#{request.format.symbol}"
      ResponseCache::SCOPES.include?(scope) ? scope : nil
    end
end
