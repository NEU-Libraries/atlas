# frozen_string_literal: true

# Creates a Delegate (binary-less Blob analogue) under a parent
# resource's `:derivative` FileSet, creating that FileSet on first use.
#
# No preservation envelope is written for the Delegate or the
# derivative FileSet — this tier is intentionally non-preservation
# (regenerable derivatives). Permissions are inherited from the parent
# resource at creation time, mirroring BlobCreator.
class DelegateCreator < ApplicationService
  def initialize(resource_id:, use:, uri:, mime_type: nil, label: nil, original_filename: nil)
    @resource_id       = resource_id
    @use               = use
    @uri               = uri
    @mime_type         = mime_type
    @label             = label
    @original_filename = original_filename
  end

  def call
    fs       = resolve_file_set
    delegate = save_delegate
    attach_to_file_set(fs, delegate)
    delegate
  end

  private

    def parent
      @parent ||= Resource.find(@resource_id)
    end

    def resolve_file_set
      existing_derivative_file_set ||
        FileSetCreator.call(work_id: parent.id, classification: Classification.derivative)
    end

    def existing_derivative_file_set
      parent.children.find do |c|
        c.is_a?(FileSet) && c.type == Classification.derivative.name
      end
    end

    def save_delegate
      delegate = Delegate.new(
        use:               @use,
        uri:               @uri,
        mime_type:         @mime_type,
        label:             @label,
        original_filename: @original_filename
      )
      delegate.permissions = parent.permissions
      Atlas.persister.save(resource: delegate)
    end

    def attach_to_file_set(file_set, delegate)
      file_set.member_ids += [delegate.id]
      Atlas.persister.save(resource: file_set)
    end
end
