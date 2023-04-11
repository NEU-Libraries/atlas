Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Defines the root path route ("/")
  # root "articles#index"
  resources :communities
  resources :collections
  resources :works
  resources :file_sets
  resources :blobs
  resources :users
end
