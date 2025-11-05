# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  respond_to :json

  before_action :require_auth

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
          @current_user = User.find_by_nuid("000000000")
          return true
        else
          # see if it's actually JWT
          user = Warden::JWTAuth::UserDecoder.new.call(token, :user, nil)
          if !user.blank?
            @current_user = user
            return true
          end
        end
      end

      render json: {}, status: :forbidden
    end
end
