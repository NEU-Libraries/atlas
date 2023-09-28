# frozen_string_literal: true

require 'rails_helper'

describe MimeHelper do
  describe '#assign_classification' do
    it 'returns a text classification enumeration for a docx file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.docx').to_s)).to eq(Classification.text)
    end

    it 'returns a presentation classification enumeration for a pptx file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.pptx').to_s)).to eq(Classification.presentation)
    end

    it 'returns a spreadsheet classification enumeration for a xlsx file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.xlsx').to_s)).to eq(Classification.spreadsheet)
    end

    it 'returns an image classification enumeration for a tif file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.tif').to_s)).to eq(Classification.image)
    end

    it 'returns an video classification enumeration for a mp4 file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.mp4').to_s)).to eq(Classification.video)
    end

    it 'returns an audio classification enumeration for a mp3 file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.mp3').to_s)).to eq(Classification.audio)
    end

    it 'returns an text classification enumeration for a csv file' do
      expect(assign_classification(Rails.root.join('spec/fixtures/files/example.csv').to_s)).to eq(Classification.text)
    end
  end
end
