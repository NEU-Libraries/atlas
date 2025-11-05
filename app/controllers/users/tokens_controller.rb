# frozen_string_literal: true

class Users::TokensController < ApplicationController

  def show
    render :json => current_user.to_json
  end

  def nuid
    if current_user.nuid == "000000000" # TODO change to a helper method
      user = User.find_by_nuid(params[:nuid])
      if !user.blank?
        result = {:token => Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]}
        render :json => result.to_json
      end
    else
      render json: {}, status: :forbidden
    end
  end

end
