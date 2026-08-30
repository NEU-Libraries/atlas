# frozen_string_literal: true

# Delegates
class DelegatesController < ApplicationController
  def show
    @delegate = Delegate.find(params[:id])
    authorize! :read, @delegate || Delegate
    return head(:not_found) if @delegate.nil?

    render :show, status: (@delegate.tombstoned ? :gone : :ok)
  end
end
