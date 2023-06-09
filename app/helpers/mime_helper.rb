# frozen_string_literal: true

module MimeHelper
  def assign_classification(file_path)
    fm = FileMagic.new(FileMagic::MAGIC_MIME)
    mime_type = hash_mime_type(fm.file(file_path))

    classification = sub_type_check(mime_type[:sub_type])
    classification = raw_type_check(mime_type[:raw_type]) if classification.blank?
    classification = ext_check(file_path) if classification.blank?
    return Classification.generic if classification.blank?

    classification
  end

  def ext_check(file_path)
    ext = File.extname(file_path).sub!('.', '')
    if %w[docx doc].include?(ext)
      Classification.text
    elsif %w[xls xlsx xlw].include?(ext)
      Classification.spreadsheet
    elsif %w[ppt pptx pps ppsx].include?(ext)
      Classification.presentation
    end
  end

  private

    # Takes a string like "image/jpeg ; encoding=binary", generated by FileMagic.
    # And turns it into the hash {raw_type: 'image', sub_type: 'jpeg', encoding: 'binary'}
    def hash_mime_type(mime_type)
      result = {}
      result[:raw_type] = mime_type.split('/').first.strip
      result[:sub_type] = mime_type.split('/').last.strip
      result
    end

    def raw_type_check(raw_type)
      case raw_type
      when 'image'
        Classification.image
      when 'video'
        Classification.video
      when 'audio'
        Classification.audio
      when 'text'
        Classification.text
      end
    end

    def sub_type_check(sub_type)
      return Classification.text if sub_type.include?('epub') || sub_type == 'pdf' || sub_type.include?('csv')

      nil
    end
end
