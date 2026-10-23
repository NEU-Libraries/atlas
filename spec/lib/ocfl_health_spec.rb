# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/ocfl_health').to_s

RSpec.describe OcflHealth do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) do
    WorkCreator.call(parent_id: collection.noid,
                     mods_xml:  Rails.root.join('spec/fixtures/files/work-mods.xml').read)
  end
  let!(:blob) do
    source = Rails.root.join('tmp', "ocfl-health-#{SecureRandom.hex(4)}.png")
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.png'), source)
    BlobCreator.call(path: source.to_s, work_id: work.noid, original_filename: 'example.png')
  end
  let(:pool) { described_class::Pool.new([TestStorage.root]) }
  let(:blob_dir) { pool.object_path(blob.noid) }

  def validate(key = blob.noid)
    described_class::ObjectValidator.new(pool.object_path(key), key: key).call
  end

  def codes(findings, severity)
    findings.select { |f| f.severity == severity }.map(&:code)
  end

  def assessment
    described_class::WorkAssessment.new(pool, work.noid).call
  end

  it 'mirrors the envelope schema version Atlas writes' do
    expect(described_class::Envelope::SCHEMA_VERSION).to eq(Preservable::ENVELOPE_SCHEMA_VERSION)
  end

  describe 'an object Atlas wrote' do
    it 'validates with nothing to repair' do
      file_sets = Work.find(work.noid).children.grep(FileSet)
      keys = [work, *file_sets, *file_sets.flat_map(&:files)].compact.map(&:noid)
      keys.each do |key|
        findings = validate(key).findings
        expect(findings.reject { |f| f.severity == :advisory }).to be_empty, "#{key}: #{findings.map(&:to_h)}"
      end
    end

    it 'grades its Work green' do
      expect(assessment.grade).to eq(:green)
      expect(assessment.facts).to include(ancestors: [community.noid, collection.noid], content_file_sets: 1)
    end
  end

  describe 'damage that loses bytes is fatal' do
    let(:content) { blob_dir.glob('v*/content/*.png').first }

    it 'catches altered content' do
      File.write(content, 'not a png')
      expect(codes(validate.findings, :fatal)).to include(:fixity_mismatch)
    end

    it 'skips the re-hash when asked, and so misses altered content' do
      File.write(content, 'not a png')
      validator = described_class::ObjectValidator.new(blob_dir, key: blob.noid, fixity: false).call
      expect(validator.findings).to be_empty
    end

    it 'catches missing content' do
      content.delete
      expect(codes(validate.findings, :fatal)).to include(:content_missing)
    end

    it 'catches an object filed under another NOID' do
      inventory = JSON.parse(blob_dir.join('inventory.json').read).merge('id' => 'urn:neu-drs:zzzzzzz')
      blob_dir.join('inventory.json').write(JSON.pretty_generate(inventory))
      expect(codes(validate.findings, :fatal)).to include(:inventory_names_another_object)
    end

    it 'grades the Work red when its MODS XML is gone' do
      mods_blob = work.mods_blob
      FileUtils.rm_rf(pool.object_path(mods_blob.noid))
      expect(assessment.grade).to eq(:red)
      expect(codes(assessment.findings, :fatal)).to include(:blob_missing, :mods_missing)
    end
  end

  describe 'damage that loses nothing is repairable' do
    it 'catches a version staged and never committed' do
      blob_dir.join('.tmp-v9-abcd').mkpath
      expect(codes(validate.findings, :repairable)).to eq([:staging_residue])
    end

    it 'catches a root inventory left behind by an interrupted head swap' do
      head = blob_dir.join('inventory.json')
      head.write("#{head.read} ")
      blob_dir.join('inventory.json.sha512').write("#{Digest::SHA512.file(head).hexdigest}  inventory.json\n")
      expect(codes(validate.findings, :repairable)).to eq([:head_inventory_mismatch])
    end

    it 'catches a sidecar that does not match' do
      blob_dir.join('inventory.json.sha512').write("#{'0' * 128}  inventory.json\n")
      expect(codes(validate.findings, :repairable)).to eq([:sidecar_mismatch])
    end

    it 'catches bytes the manifest does not account for' do
      blob_dir.glob('v*/content').first.join('stray.bin').write('stray')
      expect(codes(validate.findings, :repairable)).to eq([:unmanifested_content])
    end

    it 'grades the Work yellow when its parent is gone from disk' do
      FileUtils.rm_rf(pool.object_path(collection.noid))
      expect(assessment.grade).to eq(:yellow)
      expect(codes(assessment.findings, :repairable)).to include(:parent_missing)
    end
  end

  describe OcflHealth::CLI do
    let(:pool) { OcflHealth::Pool.new([TestStorage.root]) }

    def run(*args)
      described_class.run(['--root', TestStorage.root.to_s, *args], out: StringIO.new)
    end

    it 'exits with the worst grade' do
      expect(run(work.noid)).to eq(0)
      File.write(pool.object_path(blob.noid).glob('v*/content/*.png').first, 'x')
      expect(run(work.noid)).to eq(2)
    end

    it 'refuses to run without a root' do
      expect(described_class.run([], out: StringIO.new)).to eq(described_class::USAGE_ERROR)
    end
  end
end
