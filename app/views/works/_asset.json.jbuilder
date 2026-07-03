# frozen_string_literal: true

# Polymorphic: each element is shaped after its underlying model.
# Blob entries describe a held binary (size + filename); Delegate
# entries describe a pointer-only asset (URI + use). Clients
# pattern-match per element. Shared by assets.json (flattened) and
# file_sets.json (grouped per page) so the two shapes can't drift.
case asset
when Blob
  json.extract! asset, :noid, :mime_type, :original_filename, :size
  json.filename asset.filename
  json.label Label.find(asset.label)&.name
when Delegate
  json.extract! asset, :noid, :mime_type, :use, :uri
  json.label Label.find(asset.label)&.name
end

# Per-asset read gate (advisory — Cerberus / the IIIF auth layer enforce).
# `gated` says this asset must be authorized rather than fetched directly
# (at the IIIF server for a Delegate tier, at Atlas for a held Blob — the
# original/master and any pdf/audio/video rendition). Blobs classify by media
# type, Delegates by tier `use`. The group list behind the gate is withheld
# from guests (public traffic) to avoid leaking Grouper group names — a guest
# has no groups to match on, so `gated` alone is all they can act on.
json.gated @work.derivative_gated?(asset)
json.permission(@current_user && !@current_user.guest? ? @work.derivative_gate_for(asset) : nil)
