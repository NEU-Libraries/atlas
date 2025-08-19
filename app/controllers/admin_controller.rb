# frozen_string_literal: true

class AdminController < ApplicationController
  def token
    # TODO: check against secure value to safelist cerberus
    # for a given nuid value return a jti value
    user = User.find_by_nuid(params[:nuid])
    if !user.blank?
      result = {:token => Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]}
      render :json => result.to_json
    end
  end
end
