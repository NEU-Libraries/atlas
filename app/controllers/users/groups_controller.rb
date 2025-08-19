# frozen_string_literal: true

class Users::GroupsController < ActionController::API
  include ActionController::MimeResponds
  respond_to :json

  def groups
    @user = Warden::JWTAuth::UserDecoder.new.call(params[:token], :user, nil)
    # TODO - make JSON template to render user groups
    # user.groups
  end
end
