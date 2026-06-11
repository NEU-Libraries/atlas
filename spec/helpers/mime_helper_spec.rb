# frozen_string_literal: true

require 'rails_helper'

describe MimeHelper do
  def fixture(name)
    Rails.root.join('spec/fixtures/files', name).to_s
  end

  describe '#assign_classification' do
    it 'returns a text classification enumeration for a docx file' do
      expect(assign_classification(fixture('example.docx'))).to eq(Classification.text)
    end

    it 'returns a presentation classification enumeration for a pptx file' do
      expect(assign_classification(fixture('example.pptx'))).to eq(Classification.presentation)
    end

    it 'returns a spreadsheet classification enumeration for a xlsx file' do
      expect(assign_classification(fixture('example.xlsx'))).to eq(Classification.spreadsheet)
    end

    it 'returns an image classification enumeration for a tif file' do
      expect(assign_classification(fixture('example.tif'))).to eq(Classification.image)
    end

    it 'returns an video classification enumeration for a mp4 file' do
      expect(assign_classification(fixture('example.mp4'))).to eq(Classification.video)
    end

    it 'returns an audio classification enumeration for a mp3 file' do
      expect(assign_classification(fixture('example.mp3'))).to eq(Classification.audio)
    end

    it 'returns an text classification enumeration for a csv file' do
      expect(assign_classification(fixture('example.csv'))).to eq(Classification.text)
    end

    it 'returns a text classification enumeration for a pdf file' do
      expect(assign_classification(fixture('example.pdf'))).to eq(Classification.text)
    end

    it 'returns a generic classification enumeration for unrecognizable content' do
      expect(assign_classification(fixture('example.bin'))).to eq(Classification.generic)
    end

    it 'classifies by the name hint when the tempfile path is opaque' do
      Tempfile.create('RackMultipart') do |tmp|
        tmp.write(File.read(fixture('example.csv')))
        tmp.flush
        expect(assign_classification(tmp.path, name: 'upload.csv')).to eq(Classification.text)
      end
    end
  end

  describe '#mime_type' do
    it 'detects OOXML by content' do
      expect(mime_type(fixture('example.docx')))
        .to eq('application/vnd.openxmlformats-officedocument.wordprocessingml.document')
    end

    it 'returns the IANA-registered type for csv' do
      expect(mime_type(fixture('example.csv'))).to eq('text/csv')
    end

    it 'prefers the name hint over the path basename' do
      Tempfile.create('RackMultipart') do |tmp|
        tmp.write(File.read(fixture('example.csv')))
        tmp.flush
        expect(mime_type(tmp.path, name: 'upload.csv')).to eq('text/csv')
      end
    end
  end

  describe '#default_label' do
    it 'labels by extension for office documents' do
      expect(default_label(fixture('example.docx'))).to eq(Label.msword)
    end

    it 'labels by classification when the extension has no label' do
      expect(default_label(fixture('example.tif'))).to eq(Label.image_master)
    end

    it 'takes the extension from the name hint when present' do
      Tempfile.create('RackMultipart') do |tmp|
        tmp.write(File.read(fixture('example.pdf')))
        tmp.flush
        expect(default_label(tmp.path, name: 'upload.pdf')).to eq(Label.pdf)
      end
    end
  end
end
