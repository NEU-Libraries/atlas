# frozen_string_literal: true

# The browse vocabulary: which semantic axis a displayed MODS value belongs to,
# and which Solr field holds that axis. Atlas owns both halves of the browse
# problem -- it writes the values a consumer links to and it renders the display
# a consumer puts links into -- and those two have to agree on the value. So the
# axis lives in ONE place that MODSIndexer, CitationIndexer and WorkDecorator all
# read, rather than being restated per file.
#
# The axis NAME is the MODS-side fact, never a Solr field name. Cerberus maps an
# axis to a facet from its own Blacklight config, so a facet rename needs no
# Atlas release and the eligibility rule can move without one either.
#
# A consumer cannot derive any of this from the rendered HTML, which is why the
# markers exist at all. One <dt> ("Subjects and keywords") spans every subject
# axis, so the label does not identify the field; and the rendered string is
# free to differ from the indexed one -- a language row reads "Spanish
# (subtitles)" against an indexed "Spanish", and a name row carries its
# affiliation in brackets. Matching on display text is unsound by construction,
# not merely fragile.
module MODSBrowse
  # One axis: the token Atlas emits, and the Solr field that holds it. `solr:`
  # is nil for an axis with no browse field -- the marker is still emitted,
  # because it costs one attribute and Cerberus links only the axes its own
  # facet config names.
  Axis = Struct.new(:browse, :solr, keyword_init: true)

  # The axis of a subject heading, keyed on the MODS element neu-mods reports
  # as the heading's main term. A heading lands in the facet of its OWN axis:
  # "Salt marshes -- Massachusetts" is a topic heading with a place
  # subdivision, so it browses as a topic and not as a place.
  #
  # hierarchical_geographic is absent on purpose rather than forgotten. The
  # display composes a path across the levels while the Places facet holds the
  # narrowest level alone (see MODSIndexer#narrowest_place), so the record has
  # no single string that is both what a reader sees and what the index holds.
  # A marker either way would name a value the row does not show.
  #
  # cartographics and geographicCode never appear here because neither carries
  # heading text, so neither can be a heading's main term.
  SUBJECT_AXES = {
    'topic'          => Axis.new(browse: 'topic', solr: :subject_ssim),
    'geographic'     => Axis.new(browse: 'geographic', solr: :subject_geo_ssim),
    'temporal'       => Axis.new(browse: 'temporal', solr: :subject_era_ssim),
    'personal_name'  => Axis.new(browse: 'personal_name_subject', solr: :subject_person_ssim),
    'corporate_name' => Axis.new(browse: 'corporate_name_subject', solr: :subject_corporate_ssim),

    # A subject genre and a resource genre are the same vocabulary, so they
    # share the facet a reader already browses.
    'genre'          => Axis.new(browse: 'genre', solr: :genre_ssim),

    # Searchable, not facetable: a subject title is a work, so faceting would
    # make one bucket per record.
    'title_info'     => Axis.new(browse: 'subject_title', solr: :subject_title_tesim),

    # No browse was asked for, and the term reaches search through the
    # full-text catch-all. Marked anyway, so a later facet needs no Atlas
    # release.
    'occupation'     => Axis.new(browse: 'occupation', solr: nil)
  }.freeze

  # The axes of the non-subject rows. Each names a field whose displayed value
  # a reader might reasonably want to browse by; whether a link is OFFERED is
  # Cerberus's policy call, not Atlas's. publisher and place_of_publication are
  # marked even though the librarians excluded them, because the exclusion is
  # policy and lives with the consumer that applies it.
  CREATOR = Axis.new(browse: 'creator', solr: :creator_ssim)
  CONTRIBUTOR = Axis.new(browse: 'contributor', solr: :contributor_ssim)
  GENRE = SUBJECT_AXES.fetch('genre')
  LANGUAGE = Axis.new(browse: 'language', solr: :language_ssim)
  PLACE_OF_PUBLICATION = Axis.new(browse: 'place_of_publication', solr: :place_ssim)
  PUBLISHER = Axis.new(browse: 'publisher', solr: :publisher_ssim)
  PHOTO_CATEGORY = Axis.new(browse: 'photo_category', solr: :photo_category_ssim)

  # The axis one name belongs to, or nil for a name that belongs to neither.
  #
  # A name with a MARC creator relator is a creator; a name with roles that are
  # all something else is a contributor. The two are disjoint, which is also how
  # the display groups them: a person is credited either as a creator of the
  # work or as a contributor to it, never as both under one heading.
  #
  # A ROLE-LESS name reaches no axis. MODS makes mods:role optional and the
  # display files such a name under Creator or Contributor by its position, but
  # position is not a claim the record made -- and neither creator_ssim nor
  # contributor_ssim holds it, so a marker would promise a browse that returns
  # nothing.
  #
  # Oai::DublinCore splits the same two words differently, and that is not
  # drift. A harvester reads dc:creator and dc:contributor as assertions, so a
  # name recorded as both author and advisor is emitted as both and a role-less
  # name is emitted as a creator. A browse facet is a bucket a reader lands in,
  # so it has to be disjoint and it has to be non-empty.
  def self.name_axis(entry)
    roles = Array(entry.roles).compact_blank
    return nil if roles.empty?

    roles.any? { |role| MarcRelators.creator?(role) } ? CREATOR : CONTRIBUTOR
  end

  # The axis of one subject heading, by the axis neu-mods reports for it. nil
  # for an axis this vocabulary does not name.
  def self.subject_axis(heading)
    SUBJECT_AXES[heading.axis]
  end
end
