# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FileHelper do
  subject(:helper) { Class.new { include FileHelper }.new }

  describe '#with_tmp_file' do
    it 'holds the content under tmp/ for the block and removes it after' do
      seen = nil
      helper.with_tmp_file('<mods/>', '.xml') do |path|
        seen = path
        expect(File.read(path)).to eq('<mods/>')
        expect(path).to start_with(Rails.root.join('tmp').to_s).and end_with('.xml')
      end
      expect(File.exist?(seen)).to be(false)
    end

    it 'removes the file when the block raises' do
      seen = nil
      expect { helper.with_tmp_file('x', '.xml') { |path| (seen = path) && raise('boom') } }.to raise_error('boom')
      expect(File.exist?(seen)).to be(false)
    end

    # The OCFL adapter moves a file with new bytes into the object.
    it 'tolerates a block that moved the file away' do
      target = Rails.root.join('tmp', "moved-#{SecureRandom.hex(4)}.xml")
      helper.with_tmp_file('x', '.xml') { |path| FileUtils.mv(path, target) }
      expect(File.exist?(target)).to be(true)
    ensure
      FileUtils.rm_f(target)
    end

    it 'gives two writes in one instant different paths' do
      paths = Array.new(2) { helper.with_tmp_file('x', '.xml') { |path| path } }
      expect(paths.uniq.size).to eq(2)
    end
  end
end
