# frozen_string_literal: true

# What a guest is not told: who deposited or may edit a resource, which Grouper
# groups it names, and where its bytes sit in storage. A guest can hold no group
# but `public`, so a group list keeps only that, which is all an anonymous read
# check needs. See docs/authorization.md.
#
# Every cached view that calls this varies by caller, so its cached_render must
# pass `audience: caller_audience`.
module GuestRedaction
  PUBLIC = %w[public].freeze

  def self.guest?(user) = user.nil? || user.guest?

  def self.nuid(user, value) = guest?(user) ? nil : value

  def self.nuids(user, values) = guest?(user) ? [] : values

  def self.groups(user, groups) = guest?(user) ? Array(groups) & PUBLIC : groups

  def self.tier_map(user, map) = guest?(user) ? map.transform_values { |groups| Array(groups) & PUBLIC } : map

  def self.storage_paths(user, paths) = guest?(user) ? [] : paths

  # The resource ACL envelope Permissions#permissions builds.
  def self.permissions(user, envelope)
    return envelope unless guest?(user)

    envelope.merge(depositor: nil, proxy_uploader: nil, edit_users: [],
                   read: groups(user, envelope[:read]), edit: groups(user, envelope[:edit]))
  end
end
