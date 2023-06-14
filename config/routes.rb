# frozen_string_literal: true

Rails.application.routes.draw do
  apipie
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Defines the root path route ("/")
  # root "articles#index"
  resources :communities
  resources :collections
  resources :works
  resources :users
  resources :file_sets
  resources :files, :controller => :blobs

  # Metadata
  get '/communities/:id/mods', to: 'communities#mods', as: 'community_mods', :defaults => { :format => 'json' }
  get '/collections/:id/mods', to: 'collections#mods', as: 'collection_mods', :defaults => { :format => 'json' }
  get '/works/:id/mods', to: 'works#mods', as: 'work_mods', :defaults => { :format => 'json' }
end
