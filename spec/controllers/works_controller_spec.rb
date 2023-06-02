# frozen_string_literal: true

require 'rails_helper'

describe WorksController, type: :controller do
  render_views

  after :each do
    Valkyrie.config.metadata_adapter.persister.wipe!
  end

  describe 'GET #show' do
  end

  describe 'GET #index' do
  end

  describe 'POST #create' do
  end

  describe 'PATCH #update' do
  end

  describe 'DELETE #destroy' do
  end
end
