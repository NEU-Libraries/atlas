# frozen_string_literal: true

module MODSToJson
  include MODSExtraction

  def convert_xml_to_json(raw_xml)
    mods_obj = Mods::Record.new.from_str(raw_xml)
    record = Metadata::MODS.new

    record.main_title = extract_main_title(mods_obj)

    # Creator/Contributor
    record.names = extract_plain_names(mods_obj)

    # Language
    record.languages = mods_obj.languages

    # Date created
    record.date_created = extract_date_created(mods_obj)

    # Type of resource
    record.resource_type = mods_obj.typeOfResource.text.squish

    # Genre
    record.genres = extract_genres(mods_obj)

    # Format
    record.resource_type = mods_obj.typeOfResource.text.squish
    record.format = mods_obj.physical_description.form.text.squish
    record.extent = mods_obj.physical_description.extent.text.squish

    # Digital origin
    record.digital_origin = mods_obj.physical_description.digitalOrigin.text.squish

    # Abstract/Description
    # MODS allows multiple <abstract> elements. Calling .text on the
    # NodeSet would smoosh them together with no separator; instead
    # normalise each one and join with a paragraph break. Use the
    # paragraph-aware normaliser so blank-line breaks survive into the
    # access copy.
    record.abstract = join_paragraphs(mods_obj.abstract)

    # Related item
    record.related_series = extract_related_series(mods_obj)

    # Subjects and keywords
    record.topical_subjects = extract_topical_subjects(mods_obj)

    # Permanent URL
    record.identifiers = extract_identifiers(mods_obj)

    # Use and reproduction
    # Same multi-element handling as abstract -- two consecutive
    # <accessCondition> elements would otherwise concatenate into one
    # blob (e.g. "...?language=en)Copyright restrictions...").
    record.access_condition = join_paragraphs(mods_obj.accessCondition)

    record.json_attributes
  end

  private

    # Iterate a NodeSet, normalise each element's text as paragraphs, drop
    # empties, join with the canonical blank-line paragraph break.
    def join_paragraphs(node_set)
      parts = []
      node_set.each do |node|
        normalized = TextNormalizer.normalize_paragraphs(node.text)
        parts << normalized unless normalized.empty?
      end
      parts.join("\n\n")
    end
end
