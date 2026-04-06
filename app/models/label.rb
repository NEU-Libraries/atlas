# frozen_string_literal: true

class Label < Enumerations::Base
  # Audio
  value :audio,               name: 'Audio File',          prefix: 'audio_'
  value :audio_master,        name: 'Master Audio File',   prefix: 'master_'

  # Image
  value :image_large,         name: 'Large Image',         prefix: 'highres_'
  value :image_master,        name: 'Master Image',        prefix: 'master_'
  value :image_medium,        name: 'Medium Image',        prefix: 'medres_'
  value :image_small,         name: 'Small Image',         prefix: 'lowres_'
  value :image_thumbnail,     name: 'Thumbnail Image',     prefix: 'thumb_'

  # Documents
  value :msexcel,             name: 'Spreadsheet',         prefix: 'excel_'
  value :mspowerpoint,        name: 'PowerPoint',          prefix: 'powerpoint_'
  value :msword,              name: 'Word Document',       prefix: 'word_doc_'
  value :pdf,                 name: 'PDF',                 prefix: 'pdf_'
  value :text,                name: 'Text Document',       prefix: 'text_'
  value :epub,                name: 'EPUB',                prefix: 'epub_'
  value :dataset,             name: 'Dataset',             prefix: 'dataset_'

  # Video
  value :video,               name: 'Video File',          prefix: 'video_'
  value :video_master,        name: 'Master Video File',   prefix: 'master_'

  # Archive
  value :zip,                 name: 'Zip File',            prefix: 'zipped_'
end
