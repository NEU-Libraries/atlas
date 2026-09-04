# frozen_string_literal: true

require 'rails_helper'
require 'json-schema'

# The JSON access copy of a Work's MODS, pinned to the WorkMods schema.
#
# This is a plain request spec rather than an rswag one because rswag applies a
# single schema to every media type an operation produces
# (Rswag::Specs::SwaggerFormatter#upgrade_content!, which carries a TODO for
# content-type-specific schemas). GET /works/{id}/mods produces XML and JSON,
# so declaring the schema there would document the XML body as JSON. The
# operation's rswag example still covers the XML path; this covers the JSON
# shape, against the same registered schema the published doc shows.
RSpec.describe 'Work MODS JSON', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  # Resolved through the same registry the OpenAPI document is generated from,
  # so the assertion and the published contract cannot diverge.
  def work_mods_schema
    OpenapiSchemas.all[:WorkMods].deep_stringify_keys
  end

  # `nullable: true` is OpenAPI 3; JSON Schema spells the same thing as a union
  # with "null". rswag translates it before validating, and validating the
  # registry entry directly means doing that translation here.
  def json_schema(node)
    return node.map { |member| json_schema(member) } if node.is_a?(Array)
    return node unless node.is_a?(Hash)

    translated = node.to_h { |key, value| [key, json_schema(value)] }
    return translated unless translated.delete('nullable')

    translated.merge('type' => [translated['type'], 'null'].compact.flatten)
  end

  it 'returns a body matching the published WorkMods schema' do
    get "/works/#{work.noid}/mods", headers: { 'Accept' => 'application/json' }

    expect(response).to have_http_status(:ok)
    errors = JSON::Validator.fully_validate(json_schema(work_mods_schema), response.body)
    expect(errors).to be_empty
  end

  # A Work built from the MODS template carries almost nothing, so the example
  # above validates a body where most fields are null. This validates the
  # coverage record, which carries every element the fields claim to support --
  # without it, a wrongly typed object field passes for want of a value.
  it 'matches the schema for a record that fills every field' do
    work = WorkCreator.call(parent_id: collection.noid)
    Work.find(work.noid).mods_xml = file_fixture('mods-coverage.xml').read

    get "/works/#{work.noid}/mods", headers: { 'Accept' => 'application/json' }

    expect(response).to have_http_status(:ok)
    errors = JSON::Validator.fully_validate(json_schema(work_mods_schema), response.body)
    expect(errors).to be_empty
  end

  # The registry is the reason the schema cannot silently fall behind the
  # projection; this is the assertion that says so out loud.
  it 'documents every field the gem projects, and nothing it does not' do
    properties = work_mods_schema.dig('properties', 'work', 'properties', 'mods', 'properties')

    expect(properties.keys.map(&:to_sym)).to match_array(NEU::MODS::FIELDS.keys)
  end
end
