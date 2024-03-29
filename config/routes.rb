# frozen_string_literal: true

Rails.application.routes.draw do
  apipie
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Defines the root path route ("/")
  # root "articles#index"
  defaults format: :json do
    resources :communities
    resources :collections
    resources :works
    resources :users
    resources :file_sets
    resources :files, :controller => :blobs

    # Generics
    get '/resources/:id', to: 'resources#show'
    post '/resources/preview', to: 'resources#preview', defaults: { format: 'html' }

    # Metadata
    get '/communities/:id/mods', to: 'communities#mods', as: 'community_mods'
    get '/communities/:id/children', to: 'communities#children', as: 'community_children'
    get '/communities/:id/ancestors', to: 'communities#ancestors', as: 'community_ancestors'

    get '/collections/:id/mods', to: 'collections#mods', as: 'collection_mods'
    get '/collections/:id/children', to: 'collections#children', as: 'collection_children'
    get '/collections/:id/ancestors', to: 'collections#ancestors', as: 'collection_ancestors'

    get '/works/:id/mods', to: 'works#mods', as: 'work_mods'
  end
end
