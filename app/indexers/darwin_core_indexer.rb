# frozen_string_literal: true

# Projects four terms of a Work's Darwin Core record onto the Work's Solr doc:
# the scientific name, the country, the event date and the coordinates. Reads
# the JSON access copy, never the XML. See docs/solr-indexing.md.
#
# A value that does not parse is left out rather than failing the document: a
# bad coordinate must not cost the Work its whole index entry.
class DarwinCoreIndexer
  attr_reader :resource

  # Darwin Core's own ISO 8601 shapes for eventDate, as a year, a month, a day
  # or a full timestamp. A range ("1906-06/1907-01") is indexed by its start.
  PARTIAL_DATE = /\A(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?\z/

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    terms = resource.darwin_core&.json_attributes
    return {} if terms.blank?

    {
      dwc_scientific_name_tesim: terms['scientificName'].presence,
      dwc_scientific_name_ssim:  terms['scientificName'].presence,
      dwc_country_ssim:          terms['country'].presence,
      dwc_event_date_dtsi:       event_date(terms['eventDate']),
      dwc_coordinates_llsi:      coordinates(terms['decimalLatitude'], terms['decimalLongitude'])
    }.compact
  end

  private

    def event_date(value)
      start = value.to_s.split('/').first.to_s.strip
      return nil if start.empty?

      if (parts = PARTIAL_DATE.match(start))
        year, month, day = parts.captures
        Time.utc(year.to_i, (month || 1).to_i, (day || 1).to_i).iso8601
      else
        ActiveSupport::TimeZone['UTC'].iso8601(start).utc.iso8601
      end
    rescue ArgumentError
      nil
    end

    # The "lat,lon" string a LatLonPointSpatialField takes, or nil unless both
    # halves parse and sit inside the globe.
    def coordinates(latitude, longitude)
      lat = Float(latitude, exception: false)
      lon = Float(longitude, exception: false)
      return nil unless lat && lon && lat.between?(-90, 90) && lon.between?(-180, 180)

      "#{lat},#{lon}"
    end
end
