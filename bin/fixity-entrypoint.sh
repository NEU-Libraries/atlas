#!/usr/bin/env bash
# The fixity service's entrypoint: wake every FIXITY_INTERVAL seconds and run
# bin/ocfl-fixity-sweep while the UTC hour is inside the window. See
# docs/fixity.md.
set -uo pipefail

start=${FIXITY_WINDOW_START:-1}
end=${FIXITY_WINDOW_END:-7}
interval=${FIXITY_INTERVAL:-900}
web=/home/atlas/web

# The same roots Atlas mounts: the primary plus OCFL_EXTRA_ROOTS (name=path,...).
roots=/home/atlas/storage
IFS=',' read -ra extra <<< "${OCFL_EXTRA_ROOTS:-}"
for pair in "${extra[@]}"; do
  [[ -n "${pair// }" ]] && roots="$roots:${pair#*=}"
done
export OCFL_ROOTS=${OCFL_ROOTS:-$roots}

log() { printf '%s fixity: %s\n' "$(date -u +%FT%TZ)" "$*"; }

# A window may cross midnight, such as 22 to 4.
in_window() {
  local hour=$((10#$(date -u +%H)))
  if (( start <= end )); then
    (( hour >= start && hour < end ))
  else
    (( hour >= start || hour < end ))
  fi
}

log "started as $(id -un); window ${start}:00-${end}:00 UTC; wakes every ${interval}s; roots ${OCFL_ROOTS}"

for root in ${OCFL_ROOTS//:/ }; do
  if touch "$root/.fixity-write-probe" 2>/dev/null; then
    rm -f "$root/.fixity-write-probe"
    log "WARNING: $root is writable; mount it read-only"
  fi
done

budget=()
[[ -n "${FIXITY_BUDGET:-}" ]] && budget=(--budget "$FIXITY_BUDGET")

# Never returns: a service that exits is restarted at once, so a one-shot
# script would run in a tight loop. Priority is set here because a host-level
# setting never reaches a process dockerd starts.
while true; do
  if in_window; then
    ionice -c3 nice -n19 "$web/bin/ocfl-fixity-sweep" --until "$(printf '%02d:00' "$end")" \
      --report-to "${ATLAS_URL:?ATLAS_URL must be set}" "${budget[@]}"
    log "sweep exited $?"
  fi
  sleep "$interval"
done
