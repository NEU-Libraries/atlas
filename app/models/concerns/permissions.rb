# frozen_string_literal: true

module Permissions
  extend ActiveSupport::Concern

  STAFF_EDIT_GROUP = 'northeastern:drs:repository:staff'

  included do
    attribute :embargo_release_date, Valkyrie::Types::DateTime.optional
  end

  def embargoed?
    # is embargo_release_date
    return false if embargo_release_date.blank?

    # if it's set, has it passed >, < etc.
    embargo_release_date > DateTime.now
  end

  def depositor=(nuid)
    self.edit_users = [nuid]
  end

  # Need to clone and mutate due to valkyrie array freeze

  def add_read_group(group_name)
    self.read_groups = read_groups.map(&:clone).unshift(group_name).uniq
  end

  def delete_read_group(group_name)
    return unless read_groups.include?(group_name)

    self.read_groups = read_groups.map(&:clone).reject! { |gn| gn == group_name }
  end

  def add_edit_group(group_name)
    self.edit_groups = edit_groups.map(&:clone).unshift(group_name).uniq
  end

  def delete_edit_group(group_name)
    return if group_name == STAFF_EDIT_GROUP
    return unless edit_groups.include?(group_name)

    self.edit_groups = edit_groups.map(&:clone).reject! { |gn| gn == group_name }
  end

  def permissions
    result = {}
    result[:embargo] = embargo_release_date&.to_s
    result[:depositor] = edit_users
    result[:read] = read_groups
    result[:edit] = edit_groups

    result
  end

  def permissions=(hsh)
    # Need to allow for copying another Resource's permissions
    # Heritability, and sentinels down the line
    self.embargo_release_date = if hsh[:embargo].present?
                                  DateTime.parse(hsh[:embargo])
                                else
                                  ''
                                end

    self.edit_users = hsh[:depositor]
    self.read_groups = hsh[:read]

    incoming_edit = Array(hsh[:edit])
    self.edit_groups = if incoming_edit.include?(STAFF_EDIT_GROUP)
                         incoming_edit
                       else
                         incoming_edit.unshift(STAFF_EDIT_GROUP)
                       end
  end

  def public?
    # helper method to void spelunking into internals
    return true if read_groups.include?('public')

    false
  end

  def privatize
    delete_read_group('public')
  end

  def publicize
    add_read_group('public')
  end
end
