# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  respond_to :json

  before_action :require_auth

  private

    def parse_headers
      token_pattern = /^Bearer /
      token_header  = request.headers['Authorization']
      @token = token_header.gsub(token_pattern, '') if token_header && token_header.match(token_pattern)

      nuid_pattern = /^NUID /
      nuid_header  = request.headers['User']
      @nuid = token_header.gsub(nuid_pattern, '') if nuid_header && nuid_header.match(nuid_pattern)
    end

    def require_auth
      parse_headers

      if !@token.blank? && !Rails.application.credentials.cerberus_token.blank?
        if @token == Rails.application.credentials.cerberus_token
          if !@nuid.blank?
            user = User.find_by_nuid(@nuid)
            if !user.blank?
              @current_user = user
              return
            end
          else
            system_sign_in
            return
          end
        else
          # see if it's actually JWT
          user = Warden::JWTAuth::UserDecoder.new.call(@token, :user, nil)
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
