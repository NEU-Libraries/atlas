# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/ocfl_health').to_s

# Destructive exploration, not a regression spec: named *_probe.rb so the suite's
# *_spec.rb pattern never loads it. Run it by name:
#
#   bin/spec spec/exploration/work_health_probe.rb
#
# Builds a healthy Work, breaks one part, and records what every surface a
# consumer touches answers. The matrix lands in tmp/work_health_matrix.{json,md}.
RSpec.describe 'Work health probe', type: :request do
  Fixture = Struct.new(:work, :collection, :community, :mods_fs, :mods_blob, :content_fs, :blob, :token,
                       keyword_init: true)

  def reload(resource) = Resource.find(resource.noid)
  def save(resource) = Atlas.persister.save(resource: resource)

  def object_dir(key)
    Valkyrie.config.storage_adapter.storage_roots.values.first.object_root_for(key)
  end

  def solr
    RSolr.connect(url: SolrCore.url)
  end

  DEPOSITOR = '000000099'

  def user(nuid, **attrs)
    User.find_by(nuid: nuid) ||
      User.create!(email: "#{nuid}@example.invalid", password: SecureRandom.hex(16), nuid: nuid, **attrs)
  end

  before do
    User.find_by(role: :guest) || user('003333333', name: 'Guest', role: :guest)
    user(DEPOSITOR, name: 'Depositor, Probe', role: :standard)
    user('000000098', name: 'Staff, Probe', role: :standard, groups: [Permissions::STAFF_EDIT_GROUP])
  end

  def mods_with(token)
    Rails.root.join('spec/fixtures/files/work-mods.xml').read.sub("What's New", "What's New #{token}")
  end

  def public_collection
    community = public_community!
    collection = CollectionCreator.call(parent_id: community.noid)
    collection.publicize
    [community, save(collection)]
  end

  def attach_png(work, token)
    source = Rails.root.join('tmp', "probe-#{token}.png")
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.png'), source)
    BlobCreator.call(path: source.to_s, work_id: work.noid, original_filename: 'example.png')
  end

  # A production Work is finalized with derivatives and a handle, and a
  # baseline without them hides any finding those writes cause. The test
  # stack's handle client is unconfigured, so the mint uses a stub.
  def finalize(work)
    DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')
    post "/works/#{work.noid}/complete"
    raise "complete answered #{response.status}" unless response.successful?

    client = instance_double(HandleClient, configured?: true, mint: "DRSDEV/#{work.noid}")
    HandleMinter.call(work: work, client: client, public_base: 'https://repository.example.edu')
  end

  def build_fixture
    token = "zq#{SecureRandom.alphanumeric(8).downcase}"
    community, collection = public_collection
    work = WorkCreator.call(parent_id: collection.noid, mods_xml: mods_with(token), depositor: DEPOSITOR)
    blob = attach_png(work, token)
    finalize(work)

    file_sets = reload(work).children.grep(FileSet)
    mods_fs = file_sets.find { |fs| fs.type == Classification.descriptive_metadata.name }
    Fixture.new(work: reload(work), collection: collection, community: community, mods_fs: mods_fs,
                mods_blob: mods_fs.files.first, content_fs: file_sets.find(&:page?), blob: reload(blob), token: token)
  end

  def rewrite_mods(fix)
    work = reload(fix.work)
    work.mods_xml = yield(Nokogiri::XML(mods_with(fix.token))).to_xml
    save(work)
  end

  # name => ->(fixture) — each breaks exactly one thing.
  MUTATIONS = {
    'baseline'                                      => ->(_f) {},
    # Descriptive metadata
    'mods: title emptied'                           => lambda { |f|
      rewrite_mods(f) { |doc| doc.tap { doc.at_xpath('//mods:titleInfo/mods:title').content = '' } }
    },
    'mods: titleInfo removed'                       => lambda { |f|
      rewrite_mods(f) { |doc| doc.tap { doc.xpath('//mods:titleInfo').each(&:remove) } }
    },
    'mods: only a title left'                       => lambda { |f|
      rewrite_mods(f) do |doc|
        doc.root.element_children.reject { |el| el.name == 'titleInfo' }.each(&:remove)
        doc
      end
    },
    'mods: JSON access row deleted'                 => ->(f) { Metadata::MODS.where(valkyrie_id: f.work.noid).delete_all },
    'mods: XML object deleted from disk'            => ->(f) { FileUtils.rm_rf(object_dir(f.mods_blob.noid)) },
    'mods: XML bytes corrupted'                     => ->(f) { File.write(f.mods_blob.path, '<mods:mods') },
    'mods: Blob unlinked from FileSet'              => ->(f) { save(reload(f.mods_fs).tap { |fs| fs.member_ids = [] }) },
    'mods: descriptive FileSet deleted'             => ->(f) { Atlas.persister.delete(resource: reload(f.mods_fs)) },
    # Structure
    'parent: a_member_of nil'                       => ->(f) { save(reload(f.work).tap { |w| w.a_member_of = nil }) },
    'parent: Collection deleted'                    => ->(f) { Atlas.persister.delete(resource: reload(f.collection)) },
    'parent: Collection tombstoned'                 => ->(f) { save(reload(f.collection).tap { |c| c.tombstone(by: 'probe') }) },
    'parent: points at a Work'                      => lambda { |f|
      other = WorkCreator.call(parent_id: f.collection.noid)
      save(reload(f.work).tap { |w| w.a_member_of = other.id })
    },
    # Permissions
    'acl: read groups empty'                        => ->(f) { save(reload(f.work).tap { |w| w.read_groups = [] }) },
    'acl: edit groups empty'                        => ->(f) { save(reload(f.work).tap { |w| w.edit_groups = [] }) },
    'acl: depositor nil'                            => ->(f) { save(reload(f.work).tap { |w| w.depositor = nil }) },
    'acl: everything empty'                         => lambda { |f|
      save(reload(f.work).tap do |w|
        w.read_groups = []
        w.edit_groups = []
        w.edit_users = []
        w.depositor = nil
      end)
    },
    'acl: embargoed a year'                         => lambda { |f|
      save(reload(f.work).tap { |w| w.embargo_release_date = 1.year.from_now })
    },
    # Content
    'content: FileSet deleted'                      => lambda { |f|
      Atlas.persister.delete(resource: reload(f.blob))
      Atlas.persister.delete(resource: reload(f.content_fs))
    },
    'content: FileSet emptied'                      => ->(f) { save(reload(f.content_fs).tap { |fs| fs.member_ids = [] }) },
    'content: Blob deleted, FileSet still names it' => ->(f) { Atlas.persister.delete(resource: reload(f.blob)) },
    'content: Blob has no file_identifiers'         => ->(f) { save(reload(f.blob).tap { |b| b.file_identifiers = [] }) },
    'content: Blob object deleted from disk'        => ->(f) { FileUtils.rm_rf(object_dir(f.blob.noid)) },
    'content: Blob bytes corrupted'                 => ->(f) { File.write(f.blob.path, 'not a png') },
    'content: Blob mime and filename nil'           => lambda { |f|
      save(reload(f.blob).tap do |b|
        b.mime_type = nil
        b.original_filename = nil
      end)
    },
    # Lifecycle and derived layers
    'state: in_progress again'                      => ->(f) { save(reload(f.work).tap { |w| w.in_progress = true }) },
    'state: classification nil'                     => ->(f) { save(reload(f.work).tap { |w| w.type = nil }) },
    'state: Work envelope deleted from disk'        => ->(f) { FileUtils.rm_rf(object_dir(f.work.noid)) },
    'state: Solr document deleted'                  => lambda { |f|
      solr.delete_by_query("alternate_ids_ssim:\"id-#{f.work.noid}\"")
      solr.commit
    }
  }.freeze

  def cell(status, note = nil)
    note ? "#{status} #{note}" : status.to_s
  end

  def json_body
    response.parsed_body
  rescue StandardError
    {}
  end

  # name => ->(fixture) answering a short cell. Reads first; the last three
  # write, so they run after every read has seen the broken state.
  PROBES = {
    'show'                => lambda { |f|
      get "/works/#{f.work.noid}"
      w = json_body['work'] || {}
      notes = ["anc=#{Array(w['ancestors']).size}"]
      notes << 'no-title' if w.key?('title') && w['title'].blank?
      cell(response.status, notes.join(' '))
    },
    'show (guest)'        => lambda { |f|
      get "/works/#{f.work.noid}", headers: { 'Authorization' => '' }
      cell(response.status)
    },
    'depositor can edit'  => lambda { |f|
      Ability.new(User.find_by(nuid: DEPOSITOR)).can?(:update, Work.find(f.work.noid)) ? 'yes' : 'NO'
    },
    'staff can edit'      => lambda { |f|
      Ability.new(User.find_by(nuid: '000000098')).can?(:update, Work.find(f.work.noid)) ? 'yes' : 'NO'
    },
    'permissions'         => lambda { |f|
      get "/resources/#{f.work.noid}/permissions"
      cell(response.status)
    },
    'mods'                => lambda { |f|
      get "/works/#{f.work.noid}/mods"
      cell(response.status, (json_body.blank? || json_body == {} ? 'empty' : nil))
    },
    'mods.xml'            => lambda { |f|
      get "/works/#{f.work.noid}/mods.xml"
      cell(response.status)
    },
    'assets'              => lambda { |f|
      get "/works/#{f.work.noid}/assets"
      body = json_body
      count = body.is_a?(Array) ? body.size : Array(body['assets']).size
      cell(response.status, "n=#{count}")
    },
    'file_sets'           => lambda { |f|
      get "/works/#{f.work.noid}/file_sets"
      cell(response.status)
    },
    'content'             => lambda { |f|
      get "/files/#{f.blob.noid}/content"
      cell(response.status)
    },
    'mets'                => lambda { |f|
      get "/works/#{f.work.noid}/mets"
      cell(response.status)
    },
    'in parent listing'   => lambda { |f|
      get "/collections/#{f.collection.noid}/children"
      next cell(response.status) unless response.successful?

      response.body.include?(f.work.noid) ? 'listed' : 'ABSENT'
    },
    'search'              => lambda { |f|
      get '/resources/search', params: { q: f.token }
      next cell(response.status) unless response.successful?

      response.body.include?(f.work.noid) ? 'found' : 'MISSED'
    },
    'oai'                 => lambda { |f|
      get '/oai', params: { verb: 'GetRecord', metadataPrefix: 'oai_dc', identifier: OAI.identifier_for(f.work.noid) }
      error = response.body[/<error code="([^"]+)"/, 1]
      cell(response.status, error)
    },
    'offline'             => lambda { |f|
      a = OcflHealth::WorkAssessment.new(OcflHealth::Pool.new([TestStorage.root]), f.work.noid).call
      codes = a.findings.reject { |x| x.severity == :advisory }.map(&:code).uniq
      "#{a.grade.upcase}#{" #{codes.join(',')}" if codes.any?}"
    },
    'health check'        => lambda { |f|
      report = WorkHealthCheck.call(noid: f.work.noid, fixity: true)
      Rails.root.join('tmp/work_health_findings.log').open('a') do |log|
        report[:findings].each { |x| log.puts "#{f.token} #{x[:severity]} #{x[:code]} #{x[:subject]} #{x[:message]}" }
      end
      codes = report[:findings].reject { |x| x[:severity] == :advisory }.pluck(:code).uniq
      "#{report[:grade].upcase}#{" #{codes.join(',')}" if codes.any?}"
    },
    'reindex'             => lambda { |f|
      post "/resources/#{f.work.noid}/reindex"
      cell(response.status)
    },
    'envelope rewrite'    => lambda { |f|
      work = Work.find(f.work.noid)
      next 'no-work' if work.nil?

      file_sets = work.children.grep(FileSet)
      [work, *file_sets, *file_sets.flat_map { |fs| fs.files.compact }].each(&:write_preservation_envelope!)
      'ok'
    },
    'offline (rewritten)' => lambda { |f|
      a = OcflHealth::WorkAssessment.new(OcflHealth::Pool.new([TestStorage.root]), f.work.noid).call
      codes = a.findings.reject { |x| x.severity == :advisory }.map(&:code).uniq
      "#{a.grade.upcase}#{" #{codes.join(',')}" if codes.any?}"
    },
    'mods PUT (repair)'   => lambda { |f|
      put "/resources/#{f.work.noid}/mods",
          params: { binary: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
      cell(response.status)
    },
    'complete'            => lambda { |f|
      post "/works/#{f.work.noid}/complete"
      cell(response.status)
    }
  }.freeze

  def run_probe(probe, fix)
    instance_exec(fix, &probe)
  rescue StandardError => e
    frame = e.backtrace.find { |line| line.include?('/app/') }
    Rails.root.join('tmp/work_health_raises.log').open('a') do |log|
      log.puts "#{e.class}: #{e.message.lines.first&.strip} @ #{frame&.sub(%r{.*/app/}, 'app/')}"
    end
    "RAISE #{e.class.name.demodulize}"
  end

  def write_matrix(rows)
    Rails.root.join('tmp/work_health_matrix.json').write(JSON.pretty_generate(rows))
    header = ['mutation', *PROBES.keys]
    lines = ["| #{header.join(' | ')} |", "|#{'---|' * header.size}"]
    rows.each { |name, cells| lines << "| #{name} | #{cells.values.join(' | ')} |" }
    Rails.root.join('tmp/work_health_matrix.md').write(lines.join("\n") << "\n")
  end

  # One example per mutation, so each fixture's rows roll back with it. In one
  # transaction the storage-footprint walk slows with every fixture added.
  ROWS = {} # rubocop:disable Style/MutableConstant -- filled by the examples, written once after them

  after(:context) { write_matrix(ROWS) }

  MUTATIONS.each do |name, mutate|
    it name do
      fix = build_fixture
      begin
        instance_exec(fix, &mutate)
      rescue StandardError => e
        next ROWS[name] = { 'mutation' => "RAISE #{e.class}: #{e.message}" }
      end
      ROWS[name] = PROBES.transform_values { |probe| run_probe(probe, fix) }
      next unless name == 'baseline'

      expect(ROWS[name].values).to all(satisfy { |v| !v.to_s.start_with?('RAISE') })
    end
  end
end
