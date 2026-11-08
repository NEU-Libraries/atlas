# frozen_string_literal: true

require 'rails_helper'

# Sends every row of SetMatrix (spec/support/matrices/set_matrix.rb). See
# docs/testing.md.
RSpec.describe 'Set matrix', type: :request, default_auth: false do
  # The Set every row names, owned by :owner, readable by the reader's group and
  # editable by :set_editor. Its state is its visibility.
  def build_subjects(state)
    set = Compilation.create!(title: 'Matrix Set', depositor: users[:owner].nuid)
    set.permissions = { read: state == :public_set ? ['public', SetMatrix::READER_GROUP] : [SetMatrix::READER_GROUP],
                        edit: [], edit_users: [users[:set_editor].nuid] }
    set.save!
    { subject: set, collection: collection, work: work }
  end

  # The membership rows name a real Collection and Work: a Set refuses a NOID
  # that resolves to nothing.
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  it_behaves_like 'a flat access matrix', SetMatrix
end
