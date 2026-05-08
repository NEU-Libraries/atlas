# frozen_string_literal: true

class UsersController < ApplicationController
  def update
    return render(json: {}, status: :forbidden) unless current_user&.system?

    @user = UserProvisioner.call(
      nuid: params[:nuid],
      groups: Array(params[:groups]),
      email: params[:email],
      name: params[:name]
    )
    render :update
  end
end
