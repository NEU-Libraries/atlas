# frozen_string_literal: true

# The rswag example for a route a tombstone withholds below the operator tiers.
# The block defines the path parameters, typically `let(:id)` from one of the
# builders below; a guest then asks and is refused with the Tombstoned body.
module TombstoneWithheldExample
  def withheld_by_tombstone(&)
    response '410', 'withheld by a tombstone from everyone but admins and delegated admins',
             default_auth: false do
      class_exec(&)
      before { guest_caller! }
      schema '$ref' => '#/components/schemas/Tombstoned'
      run_test! do |response|
        expect(JSON.parse(response.body)['error']).to eq('tombstoned')
      end
    end
  end
end

# The two 410s a tombstoned resource's own record answers, which rswag folds
# into one entry: the full record to an operator, and to everyone else the
# stub (a Work or container) or the Tombstoned body (a leaf).
module TombstonedRecordExamples
  # `purged:` adds the stub a purged ID answers, on a resource's own show route.
  def tombstoned_record_responses(full:, withheld:, purged: false, &)
    description = "tombstoned: the #{full} to admins and delegated admins, #{withheld} to everyone else"
    description += "; purged: #{full}Purged to everyone" if purged
    schemas = [full, withheld] + (purged ? ["#{full}Purged"] : [])
    one_of = { oneOf: schemas.map { |s| { '$ref' => "#/components/schemas/#{s}" } } }
    operator_record_response(description, one_of, full.underscore, &)
    withheld_record_response(description, one_of, full.underscore, &)
    purged_record_responses(description, one_of, full) if purged
  end

  # A purged ID answers the same stub to an admin and a guest.
  def purged_record_responses(description, one_of, full)
    key = full.underscore
    [true, false].each do |admin|
      response '410', description, default_auth: admin do
        let(:id) { purged_public_resource!(full.constantize) }
        before { guest_caller! } unless admin
        schema one_of
        run_test! do |response|
          expect(JSON.parse(response.body)).to eq(key => { 'id' => id, 'purged' => true,
                                                           'purged_at' => PurgedIdentifier.find(id).purged_at.iso8601 })
        end
      end
    end
  end

  # The suite's default caller is the admin.
  def operator_record_response(description, one_of, key, &)
    response '410', description do
      class_exec(&)
      schema one_of
      run_test! { |response| expect(JSON.parse(response.body)[key]).to include('id') }
    end
  end

  def withheld_record_response(description, one_of, key, &)
    response '410', description, default_auth: false do
      class_exec(&)
      before { guest_caller! }
      schema one_of
      run_test! do |response|
        body = JSON.parse(response.body)
        expect(body[key]&.keys || body['error']).not_to include('description', 'original_filename', 'uri')
      end
    end
  end
end

# A guest has to pass the read gate before the tombstone answers, so each
# builder makes its resource public under a public root.
module TombstonedFixtures
  # A blank token resolves to the guest row, and some spec files never seed it.
  def guest_caller!
    User.find_by(role: :guest) ||
      User.create!(email: 'guest-tombstone-example@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
    signed_auth_headers(nil)
  end

  def tombstoned!(resource)
    resource.tombstone(by: '000000004')
    Atlas.persister.save(resource: resource)
  end

  def public_work!
    collection = CollectionCreator.call(parent_id: public_community!.noid)
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    Atlas.persister.save(resource: work)
  end

  def tombstoned_public_work!
    tombstoned!(public_work!)
  end

  # The NOID of a public resource of the class, purged.
  def purged_public_resource!(klass)
    resource = if klass == Work
                 public_work!
               else
                 container = (klass == Community ? CommunityCreator : CollectionCreator)
                             .call(parent_id: public_community!.noid)
                 container.publicize
                 Atlas.persister.save(resource: container)
               end
    ResourcePurger.call(resource: resource).first
  end

  # Empty, because a container holding a live child cannot be tombstoned.
  def tombstoned_public_container!(klass)
    creator = klass == Community ? CommunityCreator : CollectionCreator
    container = creator.call(parent_id: public_community!.noid)
    container.publicize
    tombstoned!(Atlas.persister.save(resource: container))
  end
end

RSpec.configure do |config|
  config.extend TombstoneWithheldExample, type: :request
  config.extend TombstonedRecordExamples, type: :request
  config.include TombstonedFixtures, type: :request
end
