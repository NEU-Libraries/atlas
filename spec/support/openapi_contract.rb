# frozen_string_literal: true

# Rules every operation in the generated OpenAPI documents follows, applied in
# one place so no spec author has to remember them. docs/openapi.md explains
# each one.
module OpenapiContract
  ERROR_REF        = '#/components/schemas/Error'
  UNAUTHORIZED_REF = '#/components/responses/Unauthorized'
  FORBIDDEN_REF    = '#/components/responses/Forbidden'
  NOT_FOUND_REF    = '#/components/responses/NotFound'
  NO_NOT_FOUND     = 'x-atlas-no-not-found'

  # The wording for an identity path parameter a spec left undescribed, so the
  # same name means the same thing on every route.
  PATH_PARAMETERS = {
    'id'            => 'The NOID of the resource.',
    'nuid'          => 'The person\'s NUID.',
    'email'         => 'The account\'s email address.',
    'community_id'  => 'The NOID of the Community.',
    'collection_id' => 'The NOID of the Collection.',
    'work_id'       => 'The NOID of the Work.',
    'version_id'    => 'An OCFL version, such as `v2`.',
    'type'          => 'The kind of association.'
  }.freeze
  VERBS = %w[get put post patch delete head options].freeze

  module_function

  # The written document, string-keyed, with an operationId on every operation
  # and the shared 401 on every operation that accepts a credential.
  def finish(doc)
    doc = JSON.parse(JSON.generate(doc))
    doc['paths'].each_value { |item| describe_path_parameters(item['parameters']) }
    operations(doc).each do |template, verb, op|
      describe_path_parameters(op['parameters'])
      op['operationId'] ||= operation_id(template, verb)
      attach_shared_responses(template, op, doc)
      op['responses'].each do |code, response|
        OpenapiErrorBodies.document(code, response)
        OpenapiJsonBodies.document(response)
      end
    end
    whole_document_rules!(doc)
    doc
  end

  def whole_document_rules!(doc)
    OpenapiResponseTexts.apply!(doc)
    disambiguate!(doc)
    OpenapiExamples.attach(doc)
    OpenapiSchemaPruning.apply!(doc)
  end

  def operations(doc)
    (doc['paths'] || {}).flat_map do |template, item|
      VERBS.filter_map { |verb| [template, verb, item[verb]] if item[verb].is_a?(Hash) }
    end
  end

  def describe_path_parameters(parameters)
    Array(parameters).each do |param|
      next unless param['in'] == 'path' && param['description'].blank?

      param['description'] = PATH_PARAMETERS[param['name']]
      param.compact!
    end
  end

  # Every action calls authorize! (check_authorization enforces it), so any
  # secured operation can refuse, and every path parameter is a lookup.
  def attach_shared_responses(template, operation, doc)
    responses = operation['responses']
    if secured?(operation, doc)
      responses['401'] ||= { '$ref' => UNAUTHORIZED_REF }
      responses['403'] ||= { '$ref' => FORBIDDEN_REF }
    end
    lookup = template.include?('{') && !operation.delete(NO_NOT_FOUND)
    responses['404'] ||= { '$ref' => NOT_FOUND_REF } if lookup
  end

  def secured?(operation, doc)
    Array(operation.key?('security') ? operation['security'] : doc['security']).any?(&:present?)
  end

  # Named from the controller action that serves the route, so the name follows
  # the code rather than the URL: `works#show` becomes `works_show`.
  def operation_id(template, verb)
    route = route_for(template, verb)
    route ? "#{route.defaults[:controller].tr('/', '_')}_#{route.defaults[:action]}" : path_operation_id(template, verb)
  end

  # Matched on the route's own pattern, not by recognising a sample path, so a
  # parameter constraint such as `version_id: /v\d+/` cannot defeat it.
  def route_for(template, verb)
    spec = template.gsub(/\{(\w+)\}/, ':\\1')
    Rails.application.routes.routes.find do |route|
      route.verb == verb.upcase && route.path.spec.to_s.delete_suffix('(.:format)') == spec
    end
  end

  def path_operation_id(template, verb)
    words = template.scan(/\{?\w+\}?/).map { |w| w.start_with?('{') ? "by_#{w[1..-2]}" : w }
    [verb, *words].join('_')
  end

  # One action can serve two routes, such as a type-specific and a generic
  # path. Those operations fall back to a name built from the path.
  def disambiguate!(doc)
    operations(doc).group_by { |_, _, op| op['operationId'] }.each_value do |group|
      next if group.one?

      group.each { |template, verb, op| op['operationId'] = path_operation_id(template, verb) }
    end
  end
end

# The formatter writes each document through pretty_generate, which makes it
# the one place that sees a whole document, after rswag's own clean-up, before
# it reaches disk.
module OpenapiContractFormatter
  # Every document is finished once before rswag opens a file: a document that
  # fails a rule then raises before any committed YAML is truncated.
  def stop(notification = nil)
    @config.openapi_specs.each_value { |doc| OpenapiContract.finish(doc) }
    super
  end

  private

    def pretty_generate(doc)
      super(OpenapiContract.finish(doc))
    end
end

# Declared here, ahead of rswag, because the generator runs with --dry-run, so
# no hook fires, and rswag's formatter file requires swagger_helper before it
# defines its class. rswag's own definition then reopens this one, and the
# prepend stays in front of it.
require 'rspec/core/formatters/base_text_formatter'
module Rswag
  module Specs
    class SwaggerFormatter < ::RSpec::Core::Formatters::BaseTextFormatter
      prepend OpenapiContractFormatter
    end
  end
end

# Runs on the response rswag itself requested, once rswag has validated it and
# before a run_test! block can send another request and replace `response`.
module OpenapiResponseHooks
  def assert_response_matches_metadata(metadata, ...)
    super
    OpenapiErrorBodies.check(metadata, response)
    OpenapiJsonBodies.check(metadata, response)
    OpenapiExamples.record(metadata, response, RSpec.current_example.id) if OpenapiExamples.recording?
  end
end

require 'rswag/specs'
Rswag::Specs::ExampleHelpers.prepend(OpenapiResponseHooks)
