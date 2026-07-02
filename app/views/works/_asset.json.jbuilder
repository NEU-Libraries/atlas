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
  # Per-tier read gate (advisory — Cerberus / the IIIF auth layer enforce).
  # `gated` says this tier must be authorized rather than linked at the IIIF
  # server directly; the group list behind the gate is withheld from guests
  # (public traffic) to avoid leaking Grouper group names — a guest has no
  # groups to match on, so `gated` alone is all they can act on.
  json.gated @work.derivative_gated?(asset.use)
  json.permission(@current_user && !@current_user.guest? ? @work.derivative_gate_for(asset.use) : nil)
end
