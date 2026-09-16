# frozen_string_literal: true

# Which semantic axis a displayed MODS value belongs to, and which Solr field
# holds it. MODSIndexer, CitationIndexer and WorkDecorator all read it from
# here. The axis NAME is a MODS-side fact, never a Solr field name: Cerberus
# maps an axis to a facet from its own config. See docs/mods-browse.md.
module MODSBrowse
  # `solr:` is nil for an axis with no browse field; the marker is still emitted.
  Axis = Struct.new(:browse, :solr, keyword_init: true)

  # A heading lands in the facet of its OWN axis. hierarchical_geographic,
  # cartographics and geographicCode are absent on purpose, not forgotten.
  SUBJECT_AXES = {
    'topic'          => Axis.new(browse: 'topic', solr: :subject_ssim),
    'geographic'     => Axis.new(browse: 'geographic', solr: :subject_geo_ssim),
    'temporal'       => Axis.new(browse: 'temporal', solr: :subject_era_ssim),
    'personal_name'  => Axis.new(browse: 'personal_name_subject', solr: :subject_person_ssim),
    'corporate_name' => Axis.new(browse: 'corporate_name_subject', solr: :subject_corporate_ssim),
    'genre'          => Axis.new(browse: 'genre', solr: :genre_ssim),

    # Searchable, not facetable: a subject title is a work.
    'title_info'     => Axis.new(browse: 'subject_title', solr: :subject_title_tesim),

    # Marked with no browse field, so a later facet needs no Atlas release.
    'occupation'     => Axis.new(browse: 'occupation', solr: nil)
  }.freeze

  # Whether a link is OFFERED is Cerberus's policy call, which is why publisher
  # and place_of_publication are marked despite being excluded.
  CREATOR = Axis.new(browse: 'creator', solr: :creator_ssim)
  CONTRIBUTOR = Axis.new(browse: 'contributor', solr: :contributor_ssim)
  GENRE = SUBJECT_AXES.fetch('genre')
  LANGUAGE = Axis.new(browse: 'language', solr: :language_ssim)
  PLACE_OF_PUBLICATION = Axis.new(browse: 'place_of_publication', solr: :place_ssim)
  PUBLISHER = Axis.new(browse: 'publisher', solr: :publisher_ssim)
  PHOTO_CATEGORY = Axis.new(browse: 'photo_category', solr: :photo_category_ssim)

  # Creator and contributor are DISJOINT, and a role-less name reaches neither.
  # Oai::DublinCore splits the same two words differently, deliberately.
  def self.name_axis(entry)
    roles = Array(entry.roles).compact_blank
    return nil if roles.empty?

    roles.any? { |role| MarcRelators.creator?(role) } ? CREATOR : CONTRIBUTOR
  end

  def self.subject_axis(heading)
    SUBJECT_AXES[heading.axis]
  end

  # @authorityURI is a fallback because MODS lets a record declare a vocabulary
  # by URI alone. @valueURI is NOT a candidate: it names the value, not the
  # vocabulary. #try, because non-axis labeled fields carry neither attribute.
  def self.vocabulary(entry)
    entry.try(:authority).presence || entry.try(:authority_uri).presence
  end
end
