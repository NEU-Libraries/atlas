# frozen_string_literal: true

# This correlates with Blacklight Facets and Fileset organization
# Blobs will have their own enumeration for display purposes
# i.e. Download labels in UX, binary filenames etc.
class Classification < Enumerations::Base
  value :derivative,            name: 'Derivative' # fs only
  value :map,                   name: 'Map'
  value :dataset,               name: 'Dataset'
  value :image,                 name: 'Image'
  value :video,                 name: 'Video'
  value :presentation,          name: 'Presentation'
  value :audio,                 name: 'Audio'
  value :spreadsheet,           name: 'Spreadsheet'
  value :text,                  name: 'Text'
  value :archive,               name: 'Archive'
  value :musical_notation,      name: 'Musical Notation'
  value :descriptive_metadata,  name: 'Descriptive Metadata' # fs only
  value :person,                name: 'Faculty and Staff' # model only
  value :community,             name: 'Community' # model only
  value :collection,            name: 'Collection' # model only
  value :work,                  name: 'Work' # model only
end
