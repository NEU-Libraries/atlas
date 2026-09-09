# frozen_string_literal: true

require 'rails_helper'

# atlas_rb's read guard (1.16.0), proven end-to-end. This layer is the only one
# that can prove it: the contract is "what Atlas puts on the wire, and what the
# binding does with it", and the two halves live in different repos. A unit spec
# on either side passes while the hole is open.
#
# The hole: 29 read bindings parsed or returned a response body without
# consulting the status, so an error response came back as one of four things —
# a NoMethodError on the error envelope iterated as pairs, a NoMethodError on
# nil several frames from the cause, the envelope returned as if it were data,
# or (for the `mods` bindings, which pass Atlas's rendered body through by
# design) the error text returned as a String for a consumer to render.
#
# Three of those were worse than a wrong error class, and each gets an example
# below: `Work.mods` handed back markup, `Maintenance.read` failed open on the
# one flag a client must not guess at, and `Blob.version_content` discarded the
# status so an error body could become the bytes of a downloaded file.
RSpec.describe 'Read status guard via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:archives)   { 'northeastern:drs:library:archives' }

  # A real person with no grant on anything below.
  let!(:outsider) do
    User.create!(email: 'reader-int@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000005', name: 'Student, Sam', role: :standard,
                 groups: ['northeastern:drs:library:dsg_students'])
  end

  # An assertion whose `sub` names nobody. Atlas answers `400` with
  # `{"error":"unknown principal …"}` from the before_action, so this puts a
  # real auth envelope on the wire for every binding at once — the shape a
  # consumer meets when a token outlives the account it names.
  let(:stranger_nuid) { '000000999' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe 'an auth envelope on a read' do
    it 'raises ResourceError from Work.mods instead of returning markup to render' do
      expect { AtlasRb::Work.mods(work.noid, 'html', nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError) do |error|
          expect(error.status).to eq(400)
          expect(error.message).to include('/works/', '400')
        end
    end

    # The fail-open that matters most. The endpoint's contract is that a client
    # unable to read the window cannot honour it, so a 401/400 that parses into
    # a Mash with no `read_only` key reads as "no maintenance window" precisely
    # when the answer is unknown.
    it 'raises ResourceError from Maintenance.read instead of reading as no window' do
      expect { AtlasRb::Maintenance.read(nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(400) }
    end

    it 'raises ResourceError from the list reads that used to iterate the envelope' do
      expect { AtlasRb::Work.assets(work.noid, nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError)
      expect { AtlasRb::Work.file_sets(work.noid, nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError)
      expect { AtlasRb::Collection.children(collection.noid, nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError)
    end

    it 'raises ResourceError from Person.resolve, which used to deref nil' do
      expect { AtlasRb::Person.resolve([admin_nuid], nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError)
    end

    # The two POST-shaped reads are out of the middleware's reach — it is keyed
    # on the request method — so they are guarded in the binding instead. Worth
    # its own example, because that is the seam a future batch read can miss.
    it 'raises ResourceError from the POST-shaped batch reads' do
      expect { AtlasRb::Resource.find_many([work.noid], nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError)
      expect { AtlasRb::Blob.find_many_versions(['nosuchblob'], nuid: stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError)
    end

    it 'raises ResourceError from Authentication.login rather than a parser error' do
      expect { AtlasRb::Authentication.login(stranger_nuid) }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(400) }
    end
  end

  describe 'a refusal on a read' do
    let(:restricted_collection) do
      restricted_community = CommunityCreator.call
      restricted_community.read_groups = [archives]
      restricted_community = Atlas.persister.save(resource: restricted_community)

      child = CollectionCreator.call(parent_id: restricted_community.noid)
      child.permissions = { read: [archives], edit: [archives], edit_users: [] }
      Atlas.persister.save(resource: child)
    end

    # The report's headline symptom: an Atlas refusal on the assets read used to
    # reach the consumer as a JSON::ParserError, which its controller rescue
    # renders as "this Work does not exist" — for a Work that does.
    it 'raises ResourceError carrying the 403 from Work.assets' do
      restricted_work = WorkCreator.call(parent_id: restricted_collection.noid)

      expect { AtlasRb::Work.assets(restricted_work.noid, nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
    end

    it 'raises ResourceError carrying the 403 from the admin-gated Resource.history' do
      expect { AtlasRb::Resource.history(collection.noid, nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
    end
  end

  describe 'an absent resource' do
    it 'returns nil from the single-resource reads' do
      expect(AtlasRb::Blob.versions('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Blob.ancestry('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Work.mods('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Resource.mods('nosuchnoid', 'xml', nuid: admin_nuid)).to be_nil
    end

    it 'returns nil from the list reads' do
      expect(AtlasRb::Work.assets('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Work.file_sets('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Collection.children('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Community.children('nosuchnoid', nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Work.linked_members('nosuchnoid', nuid: admin_nuid)).to be_nil
    end

    # The point of nil rather than []: a caller can tell "no such container"
    # from "an empty container", which mean different things to a UI.
    it 'returns an empty collection for a container that is genuinely empty' do
      empty = CollectionCreator.call(parent_id: community.noid)

      expect(AtlasRb::Collection.children(empty.noid, nuid: admin_nuid)).to eq([])
      expect(AtlasRb::Work.assets(work.noid, nuid: admin_nuid)).to eq([])
    end
  end

  # A streamed read cannot raise, and this is the example that shows why: the
  # error envelope really is yielded as a chunk, because on_data fires as bytes
  # arrive and nothing knows the status yet. Discarding the status left the
  # caller unable to tell those bytes from the file it asked for — an error page
  # saved to disk under the download filename. Handing the status back is the
  # only fix available at this seam.
  describe 'the streamed reads' do
    it 'hands version_content the status alongside the bytes it streamed' do
      chunks = []
      result = AtlasRb::Blob.version_content('nosuchblob', 'v1', nuid: stranger_nuid) { |c| chunks << c }

      expect(chunks.join).to include('unknown principal')
      expect(result[:status]).to eq(400)
      expect(result[:headers]).to be_a(Hash)
    end
  end
end
