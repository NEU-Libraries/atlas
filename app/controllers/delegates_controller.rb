# frozen_string_literal: true

# Delegates
class DelegatesController < ApplicationController
  def show
    @delegate = Delegate.find(params.expect(:id))
    authorize! :read, @delegate || Delegate
    return head(:not_found) if @delegate.nil?

    refuse_tombstoned!(@delegate)
    @embargo_withheld = embargo_withholds?(@delegate.read_authority)
    render :show, status: (@delegate.tombstone_source ? :gone : :ok)
  end
end
