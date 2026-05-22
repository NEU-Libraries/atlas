# frozen_string_literal: true

class Users::TokensController < ApplicationController

  def show
    authorize! :read, User
    render :json => @current_user.to_json
  end

  def nuid
    authorize! :mint_token, User

    user = User.find_by_nuid(params[:nuid])
    if !user.blank?
      result = {:token => Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]}
      render :json => result.to_json
    end
  end

end
