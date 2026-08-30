# frozen_string_literal: true

# People — neutral curatorial identities (see Person). Addressable endpoints
# are keyed by NOID (like Work/Collection), keeping the staff-facing NUID
# server-side — NEU IT Security treats surfacing NUIDs in public URLs as an
# enumeration risk. NUID stays the key only where it must: create (one Person
# per NUID, the correlation key) and the ?nuids= resolve batch (NuidResolver,
# never user-facing). Reads sit on the authenticated floor; create/update/
# affiliation writes are :system + admin.
class PeopleController < ApplicationController
  include LazyPagination
  include StaleObjectRetry
  include Auditable
  include CachedResponses

  # GET /people            — paginated list of all Persons (?page, ?per_page).
  #                           The People-index source; each row carries the NOID
  #                           (public address) + server-side nuid.
  # GET /people?nuids=a,b,c — batch resolve to authoritative display_name
  #                           (supersedes User.resolve); unresolved nuids drop.
  def index
    authorize! :read, Person

    if params[:nuids].present?
      # Batch resolve: return every matched Person (no truncation), so page
      # size follows the match count. Still paginated for a uniform shape.
      people = Atlas.query.custom_queries.find_people_by_nuids(nuids: batch_nuids)
      @pagination, items = paginate_array(people)
    else
      @pagination, items = paginate_model(Person, per_page: params[:per_page])
    end
    # Persons are minted public (PersonCreator), so the filter is normally a
    # no-op — it is here so a Person whose ACL is later narrowed stops showing
    # up in the roster without anyone having to remember this endpoint.
    @people = readable(items).map(&:decorate)
    PersonAffiliationPreloader.call(people: @people)
  end

  # GET /people/:noid
  def show
    person = find_person
    authorize! :read, person || Person
    return head(:not_found) if person.nil?

    cached_render('people.show', person) do
      @person = person.decorate
      render :show
    end
  end

  # POST /people — one Person per NUID; a duplicate is a 409.
  def create
    authorize! :create, Person
    return render_conflict if Atlas.query.custom_queries.find_person_by_nuid(nuid: params[:nuid]).present?

    @person = PersonCreator.call(
      nuid:              params[:nuid],
      display_name:      params[:display_name],
      bio:               params[:bio],
      orcid:             params[:orcid],
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    ).decorate
    render :show, status: :created
  end

  # PATCH /people/:noid — librarian edits to authority fields. NUID is the
  # immutable correlation key and is not patchable here. Person carries no
  # per-instance ACL, so authorization is class-level (:system + admin) and
  # runs before the lookup.
  def update
    authorize! :update, Person
    with_stale_object_retry do
      @person = find_person
      return head(:not_found) if @person.nil?

      %w[display_name bio orcid].each do |attr|
        @person.public_send("#{attr}=", params[attr]) if params.key?(attr)
      end
      @person = Atlas.persister.save(resource: @person)
      audit!(resource: @person, action: 'update', change_type: 'metadata')
    end
    @person = @person.decorate
    render :show
  end

  # POST /people/:noid/affiliations { community_id } — idempotent add.
  def add_affiliation
    authorize! :update, Person
    with_stale_object_retry do
      @person = find_person
      return head(:not_found) if @person.nil?

      community = resolve_community
      return render_unknown_community if community.nil?

      @person.affiliated_community_ids = (Array(@person.affiliated_community_ids) + [community.id]).uniq
      @person = Atlas.persister.save(resource: @person)
      audit!(resource: @person, action: 'add_affiliation', change_type: 'structural',
             payload: { community_id: community.noid })
    end
    @person = @person.decorate
    render :show
  end

  # DELETE /people/:noid/affiliations/:community_id — tolerant remove.
  def remove_affiliation
    authorize! :update, Person
    with_stale_object_retry do
      @person = find_person
      return head(:not_found) if @person.nil?

      community = resolve_community
      @person.affiliated_community_ids =
        Array(@person.affiliated_community_ids).reject { |id| id == community&.id }
      @person = Atlas.persister.save(resource: @person)
      audit!(resource: @person, action: 'remove_affiliation', change_type: 'structural',
             payload: { community_id: community&.noid })
    end
    @person = @person.decorate
    render :show
  end

  private

    # Addressable lookups are by NOID (Resource.find resolves the alternate_id),
    # scoped to Person so a non-Person NOID reads as absent. The NUID-keyed
    # find_person_by_nuid is reserved for create's uniqueness guard and the
    # ?nuids= resolve batch.
    def find_person
      resource = Resource.find(params[:id])
      resource if resource.is_a?(Person)
    end

    # Affiliations are to Communities specifically; a non-Community id is
    # treated as unknown.
    def resolve_community
      resource = Resource.find(params[:community_id])
      resource.is_a?(Community) ? resource : nil
    end

    def batch_nuids
      params[:nuids].to_s.split(',').map(&:strip).compact_blank
    end

    def render_conflict
      render json:   { error: "a person already exists for nuid #{params[:nuid]}", code: 'duplicate_nuid' },
             status: :conflict
    end

    def render_unknown_community
      render json:   { error: "unknown community #{params[:community_id]}", code: 'unknown_community' },
             status: :unprocessable_entity
    end
end
