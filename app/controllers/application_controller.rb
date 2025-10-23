# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  respond_to :json

  private

    def auth_token
      pattern = /^Bearer /
      header  = request.headers['Authorization']
      token = header.gsub(pattern, '') if header && header.match(pattern)
    end

    def require_auth
      token = auth_token

      if !token.blank? && !Rails.application.credentials.cerberus_token.blank?
        if token == Rails.application.credentials.cerberus_token
          return true
        end
      end

      render json: {}, status: :forbidden
    end
end
