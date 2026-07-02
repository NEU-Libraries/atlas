# frozen_string_literal: true

Rails.application.routes.draw do
  mount Rswag::Api::Engine => '/api-docs'
  get '/docs', to: 'docs#show'

  # Human auth is delegated to Cerberus (SSO) — Atlas never takes a password,
  # so the devise sessions (sign_in/out) and registrations (sign_up) routes are
  # skipped (F1). The devise modules stay on User and the :user Warden mapping
  # is still established (warden-jwt's decoder needs it), leaving a door open
  # for future non-SSO service accounts without exposing public login/signup.
  # The token endpoints (/nuid, /user) are declared manually below.
  devise_for :users, skip: %i[sessions registrations]

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
        patch :derivative_permissions, action: :update_derivative_permissions
        patch :full_text, action: :update_full_text
        patch :parent, action: :update_parent
      end
    end
    resources :file_sets do
      member do
        patch :iiif_service, action: :update_iiif_service
      end
    end
    resources :files, :controller => :blobs do
      member do
        get :content
        # Blob → parent FileSet → parent Work resolver. The download path
        # (DownloadsController) is keyed only by blob id, so impression capture
        # rolls a download up to its containing Work by resolving here.
        get :ancestry
        # Binary version read surface — the counterpart to the MODS version
        # pair (/resources/:id/mods/versions[/:version_id]). List is admin-
        # gated (carries edit attribution); per-version content rides the
        # Blob read floor; rollback is a non-destructive write. The trailing
        # /content disambiguates the per-version stream from the list, and the
        # vN constraint keeps a `.xml`-style suffix out of the id.
        get :versions
        get 'versions/:version_id/content', action: :version_content,
            as: :version_content, constraints: { version_id: /v\d+/ }
        post :rollback
      end
    end
    resources :delegates, only: :show

    # People — neutral curatorial identities. Addressable endpoints are keyed
    # by NOID (like /works/:id), keeping the staff-facing NUID server-side
    # (NEU IT Security: don't surface NUIDs in public URLs). NUID stays the key
    # only for create (one Person per NUID) and the ?nuids= resolve batch.
    # Reads on the authenticated floor; create/update/affiliation writes are
    # :system + admin. Affiliations are an audited Person↔Community edge.
    get    '/people',                                 to: 'people#index'
    post   '/people',                                 to: 'people#create'
    get    '/people/:id',                             to: 'people#show',   as: 'person'
    patch  '/people/:id',                             to: 'people#update'
    post   '/people/:id/affiliations',               to: 'people#add_affiliation'
    delete '/people/:id/affiliations/:community_id',  to: 'people#remove_affiliation'

    # Compilations (DRS "Sets") — AR-tier personal curation, recipe-based.
    # Membership routes mutate one recipe line each and re-render the
    # compilation; /contents resolves the recipe against Solr for consumers.
    resources :compilations do
      member do
        get    :contents
        post   'included_collections',                to: 'compilations#add_included_collection'
        delete 'included_collections/:collection_id', to: 'compilations#remove_included_collection'
        post   'included_works',                      to: 'compilations#add_included_work'
        delete 'included_works/:work_id',             to: 'compilations#remove_included_work'
        post   'exclusions',                          to: 'compilations#add_exclusion'
        delete 'exclusions/:work_id',                 to: 'compilations#remove_exclusion'
      end
    end

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

    # Operational, :system-gated Solr re-projection. Re-derives a resource's
    # Solr doc (and, for _subtree, its descendant containers + the Works
    # beneath them) from the current Postgres/OCFL source of truth — no
    # lifecycle transition, no audit, no optimistic-lock bump. The supported
    # lever after an indexer ships/changes and finalized resources carry a
    # stale projection. Synchronous by design; Cerberus chunks a large subtree.
    post '/resources/:id/reindex', to: 'resources#reindex'
    post '/resources/:id/reindex_subtree', to: 'resources#reindex_subtree'

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
    # Work-level METS (physical structMap = page order); 404 until the
    # Work has been completed.
    get '/works/:id/mets', to: 'works#mets', as: 'work_mets'

    # Linked membership (DAG overlay): a Work in additional Collections.
    get    '/works/:id/linked_members', to: 'works#linked_members', as: 'work_linked_members'
    post   '/works/:id/linked_members', to: 'works#add_linked_member'
    delete '/works/:id/linked_members/:collection_id', to: 'works#remove_linked_member'

    get '/file_sets/:id/mets', to: 'file_sets#mets', as: 'file_set_mets'

    # Downloads
    get '/works/:id/assets', to: 'works#assets', as: 'work_assets'

    # Ordered page listing (multipage Works): one entry per page-bearing
    # FileSet, position ASC, with each page's downloadable assets nested.
    # Unpaginated by design — manifest assembly needs the whole sequence
    # in one read (books run to hundreds of pages, not thousands).
    get '/works/:id/file_sets', to: 'works#file_sets', as: 'work_file_sets'

    # Housekeeping
    get '/reset', to: 'maintenance#reset', as: 'reset'

    # NUID — mint a personal-access JWT (POST) / revoke all of a user's tokens
    # by rotating its jti (DELETE). Both system-gated; nuid carried in the body.
    post   '/nuid', to: 'users/tokens#nuid',   as: 'nuid'
    delete '/nuid', to: 'users/tokens#revoke', as: 'revoke_token'

    # User details
    get '/user', to: 'users/tokens#show', as: 'user_show'

    # User directory (read-only): typeahead search / batch resolve + single
    # NUID resolve. Minimal disclosure (nuid + name only).
    get '/users', to: 'users#index', as: 'users_directory'
    get '/users/by_nuid/:nuid', to: 'users#show', as: 'user_directory_entry'

    # SSO user provisioning (system-only)
    put '/users/by_nuid/:nuid', to: 'users#update', as: 'user_provision'
  end
end
