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
        patch :thumbnails, action: :update_thumbnails
        patch :parent, action: :update_parent
      end
    end
    resources :collections do
      member do
        post :tombstone
        post :restore
        patch :thumbnails, action: :update_thumbnails
        patch :parent, action: :update_parent
      end
    end
    resources :works do
      member do
        post :tombstone
        post :restore
        post :complete
        patch :thumbnails, action: :update_thumbnails
        patch :image_derivatives, action: :update_image_derivatives
        patch :parent, action: :update_parent
      end
    end
    # resources :users
    resources :file_sets
    resources :files, :controller => :blobs do
      get :content, :on => :member
    end
    resources :delegates, only: :show

    # Generics
    get '/resources/:id', to: 'resources#show'
    get '/resources/:id/permissions', to: 'resources#permissions'
    get '/resources/:id/history', to: 'audit_events#index', as: 'resource_history'
    # MODS version history (type-agnostic, like /history and /permissions —
    # the descriptive-metadata Blob lookup is identical across Work/Collection/
    # Community). List carries audit-derived actor attribution (admin-gated);
    # fetch serves a version's raw historical XML. JSON is not version-
    # recoverable, so the fetch is XML-only — default the format to xml and
    # constrain :version_id to the OCFL vN grammar so a trailing `.xml` parses
    # as the format, not part of the id.
    get '/resources/:id/mods/versions', to: 'resources#mods_versions', as: 'resource_mods_versions'
    get '/resources/:id/mods/versions/:version_id', to: 'resources#mods_version',
        as: 'resource_mods_version', defaults: { format: 'xml' }, constraints: { version_id: /v\d+/ }
    post '/resources/preview', to: 'resources#preview', defaults: { format: 'html' }
    # Batch resolver: many noids/ids -> lightweight digests in one round-trip.
    # Collapses the per-id find fan-out on the Cerberus side (breadcrumbs,
    # linked members, load destinations). Tolerant: unresolvable ids are
    # dropped, so the result may be shorter than the input and is not
    # order-guaranteed — callers index by noid.
    post '/resources/find_many', to: 'resources#find_many'

    # Session-scoped audit emit (no resource to hang on): impersonation
    # start/end. Admin-gated. See AtlasRb::AuditEvent.emit.
    post '/audit_events', to: 'audit_events#create', as: 'audit_events'

    # Metadata
    get '/communities/:id/mods', to: 'communities#mods', as: 'community_mods'
    get '/communities/:id/children', to: 'communities#children', as: 'community_children'
    get '/communities/:id/ancestors', to: 'communities#ancestors', as: 'community_ancestors'

    get '/collections/:id/mods', to: 'collections#mods', as: 'collection_mods'
    get '/collections/:id/children', to: 'collections#children', as: 'collection_children'
    get '/collections/:id/ancestors', to: 'collections#ancestors', as: 'collection_ancestors'

    get '/works/:id/mods', to: 'works#mods', as: 'work_mods'

    # Linked membership (DAG overlay): a Work in additional Collections.
    get    '/works/:id/linked_members', to: 'works#linked_members', as: 'work_linked_members'
    post   '/works/:id/linked_members', to: 'works#add_linked_member'
    delete '/works/:id/linked_members/:collection_id', to: 'works#remove_linked_member'

    get '/file_sets/:id/mets', to: 'file_sets#mets', as: 'file_set_mets'

    # Downloads
    get '/works/:id/assets', to: 'works#assets', as: 'work_assets'

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
