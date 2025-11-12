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
          system_sign_in
          return
        else
          # see if it's actually JWT
          user = Warden::JWTAuth::UserDecoder.new.call(token, :user, nil)
          if !user.blank?
            @current_user = user
            return
          end
        end
      end

      # render json: {}, status: :forbidden
      # if not, make current_user a shell user with zero permissions
      # this will allow current_user to not nil out, and for permission checking to work
      # everywhere as intended
      guest_sign_in
    end

    def system_sign_in
      # TODO - environment protection: in prod, restrict to IP address
      @current_user = User.find_by_role(:system) # only one should exist
    end

    def guest_sign_in
      @current_user = User.find_by_role(:guest) # only one should exist
    end
end
