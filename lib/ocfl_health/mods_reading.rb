# frozen_string_literal: true

module OcflHealth
  # What the grade needs from a MODS XML file: whether it parses, its title and
  # how many subjects it carries. REXML, because the tool runs without the
  # bundle and so without Nokogiri.
  class ModsReading
    NS = { 'mods' => 'http://www.loc.gov/mods/v3' }.freeze

    attr_reader :title, :subjects, :error

    def self.read(path)
      new(path.read)
    end

    def initialize(xml)
      doc = REXML::Document.new(xml)
      title = REXML::XPath.first(doc, '//mods:titleInfo/mods:title', NS)&.text.to_s.strip
      @title = title.empty? ? nil : title
      @subjects = REXML::XPath.match(doc, '//mods:subject/*', NS).size
    rescue REXML::ParseException => e
      @error = e.message.lines.first&.strip
    end
  end
end
