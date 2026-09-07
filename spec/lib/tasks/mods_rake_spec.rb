# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'atlas:mods rake tasks' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('atlas:mods:reproject')
  end

  before(:each) { Rake::Task['atlas:mods:reproject'].reenable }
  after { Atlas.persister.wipe! }

  describe 'atlas:mods:reproject' do
    # A field that changes shape between gem versions leaves stored rows
    # attr_json can no longer cast -- languages went from a string to an entry,
    # and reading one raised AttrJson::Type::Model::BadCast. The XML is the
    # source of truth, so the row is rebuilt from it.
    it 'rebuilds an access copy stored in an older projection shape' do
      community = Atlas.persister.save(resource: Community.new)
      collection = CollectionCreator.call(parent_id: community.noid)
      work = WorkCreator.call(parent_id: collection.noid)
      work.mods_xml = <<~XML
        <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
          <mods:titleInfo usage="primary"><mods:title>A Work</mods:title></mods:titleInfo>
          <mods:language><mods:languageTerm type="text">English</mods:languageTerm></mods:language>
        </mods:mods>
      XML

      # Written as raw jsonb: assigning through attr_json would cast, which is
      # the very thing the old row cannot survive.
      stale = Metadata::MODS.find_by(valkyrie_id: work.noid)
      stored = Metadata::MODS.connection
                             .select_value("SELECT json_attributes FROM metadata_mods WHERE id = #{stale.id}")
      Metadata::MODS.connection.update(
        Metadata::MODS.sanitize_sql(['UPDATE metadata_mods SET json_attributes = ? WHERE id = ?',
                                     JSON.parse(stored).merge('languages' => ['English']).to_json, stale.id])
      )

      Rake::Task['atlas:mods:reproject'].invoke

      rebuilt = Metadata::MODS.find_by(valkyrie_id: work.noid)
      expect(rebuilt.languages.map(&:term)).to eq(['English'])
    end

    it 'skips a resource with nowhere to read MODS from rather than raising' do
      Atlas.persister.save(resource: Work.new)

      expect { Rake::Task['atlas:mods:reproject'].invoke }.not_to raise_error
    end
  end
end
