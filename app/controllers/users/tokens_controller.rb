# frozen_string_literal: true

class Users::TokensController < ApplicationController
  before_action :require_auth

  def show
    user = Warden::JWTAuth::UserDecoder.new.call(params[:token], :user, nil)
    render :json => user.to_json
  end

  def token
    # for a given nuid value return a jti value
    user = User.find_by_nuid(params[:nuid])
    if !user.blank?
      result = {:token => Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]}
      render :json => result.to_json
    end
  end

end
