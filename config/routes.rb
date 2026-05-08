# frozen_string_literal: true

Rails.application.routes.draw do
  mount Rswag::Api::Engine => '/api-docs'
  get '/docs', to: 'docs#show'

  devise_for :users, controllers: {
    sessions: "users/sessions",
    registrations: "users/registrations",
    tokens: "users/tokens"
  }

  defaults format: :json do
    resources :communities do
      member do
        post :tombstone
        post :restore
      end
    end
    resources :collections do
      member do
        post :tombstone
        post :restore
      end
    end
    resources :works do
      member do
        post :tombstone
        post :restore
      end
    end
    # resources :users
    resources :file_sets
    resources :files, :controller => :blobs do
      get :content, :on => :member
    end

    # Generics
    get '/resources/:id', to: 'resources#show'
    get '/resources/:id/permissions', to: 'resources#permissions'
    post '/resources/preview', to: 'resources#preview', defaults: { format: 'html' }

    # Metadata
    get '/communities/:id/mods', to: 'communities#mods', as: 'community_mods'
    get '/communities/:id/children', to: 'communities#children', as: 'community_children'
    get '/communities/:id/ancestors', to: 'communities#ancestors', as: 'community_ancestors'

    get '/collections/:id/mods', to: 'collections#mods', as: 'collection_mods'
    get '/collections/:id/children', to: 'collections#children', as: 'collection_children'
    get '/collections/:id/ancestors', to: 'collections#ancestors', as: 'collection_ancestors'

    get '/works/:id/mods', to: 'works#mods', as: 'work_mods'

    get '/file_sets/:id/mets', to: 'file_sets#mets', as: 'file_set_mets'

    # Downloads
    get '/works/:id/files', to: 'works#blobs', as: 'work_files'

    # Housekeeping
    get '/reset', to: 'maintenance#reset', as: 'reset'

    # NUID
    post '/nuid', to: 'users/tokens#nuid', as: 'nuid'

    # User details
    get '/user', to: 'users/tokens#show', as: 'user_show'

    # SSO user provisioning (system-only)
    put '/users/by_nuid/:nuid', to: 'users#update', as: 'user_provision'
  end
end
