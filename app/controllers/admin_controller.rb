# frozen_string_literal: true

class AdminController < ApplicationController
  def token
    # check against secure value to safelist cerberus
    # for a given nuid value return a jti value
    render :json => Warden::JWTAuth::UserEncoder.new.call(User.find_by_nuid(params[:nuid]), :users, nil)[1]["jti"]
  end
end
