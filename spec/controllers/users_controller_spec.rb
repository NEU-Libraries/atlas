# frozen_string_literal: true

require 'rails_helper'

describe UsersController, type: :controller do
  render_views

  after :each do
    Valkyrie.config.metadata_adapter.persister.wipe!
  end
end
