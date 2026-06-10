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
  value :structural_metadata,   name: 'Structural Metadata' # fs only — hosts a Work-level METS Blob
  value :person,                name: 'Faculty and Staff' # model only
  value :community,             name: 'Community' # model only
  value :collection,            name: 'Collection' # model only
  value :work,                  name: 'Work' # model only
  value :generic,               name: 'File' # blob/fs fallback

  # Metadata-container FileSets: descriptive (MODS) and structural (METS).
  # Excluded from asset/page listings, never seed their own FileSet-level
  # METS, and 404 on /file_sets/:id/mets.
  def self.metadata?(name)
    [descriptive_metadata.name, structural_metadata.name].include?(name)
  end

  # A FileSet of this classification gets a preservation envelope written
  # to OCFL. `:derivative` FileSets host fungible Delegates pointing at
  # external assets — no preservation-critical state lives there.
  def self.preserved?(name)
    name != derivative.name
  end
end
