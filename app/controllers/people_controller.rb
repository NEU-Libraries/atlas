# frozen_string_literal: true

# People — neutral curatorial identities (see Person). Addressed by NUID (the
# correlation key consumers hold), not NOID. Reads sit on the authenticated
# floor; create/update/affiliation writes are :system + admin (name authority
# and affiliations are operational/curatorial, not a self-service user action).
class PeopleController < ApplicationController
  include LazyPagination
  include StaleObjectRetry
  include Auditable

  # GET /people            — paginated list of all Persons.
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
      @pagination, items = paginate_model(Person)
    end
    @people = items.map(&:decorate)
  end

  # GET /people/:nuid
  def show
    authorize! :read, Person
    @person = find_person
    return head(:not_found) if @person.nil?

    @person = @person.decorate
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
      title:             params[:title],
      actor_nuid:        @current_user&.nuid,
      on_behalf_of_nuid: @on_behalf_of
    ).decorate
    render :show, status: :created
  end

  # PATCH /people/:nuid — librarian edits to authority fields. NUID is the
  # immutable correlation key and is not patchable here. Person carries no
  # per-instance ACL, so authorization is class-level (:system + admin) and
  # runs before the lookup.
  def update
    authorize! :update, Person
    with_stale_object_retry do
      @person = find_person
      return head(:not_found) if @person.nil?

      %w[display_name bio orcid title].each do |attr|
        @person.public_send("#{attr}=", params[attr]) if params.key?(attr)
      end
      @person = Atlas.persister.save(resource: @person)
      audit!(resource: @person, action: 'update', change_type: 'metadata')
    end
    @person = @person.decorate
    render :show
  end

  # POST /people/:nuid/affiliations { community_id } — idempotent add.
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

  # DELETE /people/:nuid/affiliations/:community_id — tolerant remove.
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

    def find_person
      Atlas.query.custom_queries.find_person_by_nuid(nuid: params[:nuid])
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
