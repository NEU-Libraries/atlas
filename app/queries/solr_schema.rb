# frozen_string_literal: true

# What the Solr schema says about a field: whether it is stored, and which
# fields copy their text into it. Read from Solr's schema API once per process,
# so the search explanation follows schema.xml without a copy of it here. See
# docs/search.md.
class SolrSchema
  def self.current
    @current ||= new(Atlas.index_adapter.connection.get('schema')['schema'])
  end

  def initialize(schema)
    @fields  = schema['fields'].index_by { |field| field['name'] }
    @dynamic = schema['dynamicFields'].sort_by { |field| -field['name'].length }
    @types   = schema['fieldTypes'].index_by { |type| type['name'] }
    @copies  = schema['copyFields']
  end

  def known?(name)
    !definition(name).nil?
  end

  # A field's own property overrides its type's, and a property set on neither
  # means stored, as it does in Solr.
  def stored?(name)
    field = definition(name)
    return false if field.nil?

    field.fetch('stored') { @types.dig(field['type'], 'stored') } != false
  end

  # Wildcard sources are skipped. They feed only the all_text_timv catch-all,
  # which the search handler does not read.
  def copy_sources(dest)
    @copies.select { |copy| copy['dest'] == dest && copy['source'].exclude?('*') }.pluck('source')
  end

  private

    # An explicit field wins, then the longest matching dynamic pattern, which
    # is the order Solr itself resolves them in.
    def definition(name)
      @fields[name] || @dynamic.find { |field| glob?(field['name'], name) }
    end

    def glob?(pattern, name)
      if pattern.start_with?('*')
        name.end_with?(pattern.delete_prefix('*'))
      else
        name.start_with?(pattern.delete_suffix('*'))
      end
    end
end
