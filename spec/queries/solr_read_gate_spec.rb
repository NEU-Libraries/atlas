# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SolrReadGate do
  let(:host) { Class.new { include SolrReadGate }.new }

  def gate(user)
    host.send(:read_gate_fq, user)
  end

  def build_user(role:, nuid: nil, groups: [])
    User.new(role: role, nuid: nuid, groups: groups)
  end

  it 'leaves an admin ungated' do
    expect(gate(build_user(role: :admin, nuid: '000000004'))).to be_nil
  end

  it 'gates :system like anyone else, because its list reads are not scoped to a person' do
    expect(gate(build_user(role: :system, nuid: '000000000'))).to be_present
  end

  it 'gives a guest the public clause only' do
    expect(gate(build_user(role: :guest))).to eq('(read_access_group_ssim:("public"))')
  end

  it 'gives a nil user the public clause only' do
    expect(gate(nil)).to eq('(read_access_group_ssim:("public"))')
  end

  it 'admits read groups, edit groups, the edit user and the depositor' do
    user = build_user(role: :standard, nuid: '001234567', groups: ['northeastern:drs:staff'])
    expect(gate(user)).to eq(
      '(read_access_group_ssim:("public" OR "northeastern:drs:staff")) OR ' \
      '(edit_access_group_ssim:("northeastern:drs:staff")) OR ' \
      '(edit_access_person_ssim:"001234567") OR (depositor_ssi:"001234567")'
    )
  end

  it 'keeps a group name with spaces and operators as one phrase' do
    user = build_user(role: :standard, groups: ['a (b) OR c'])
    expect(gate(user)).to include('"a (b) OR c"')
  end

  it 'escapes a quote and a backslash inside a phrase' do
    user = build_user(role: :standard, groups: ['say "hi" \\ bye'])
    expect(gate(user)).to include('"say \\"hi\\" \\\\ bye"')
  end
end
