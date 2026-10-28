#!/usr/bin/env bash
# The fixity service's entrypoint: wake every FIXITY_INTERVAL seconds and run
# bin/ocfl-fixity-sweep once in each night's UTC window. See docs/fixity.md.
set -uo pipefail

start=${FIXITY_WINDOW_START:-1}
end=${FIXITY_WINDOW_END:-7}
interval=${FIXITY_INTERVAL:-900}
sweep=${FIXITY_SWEEP:-/home/atlas/web/bin/ocfl-fixity-sweep}

# The window the last finished sweep ran in, so FIXITY_BUDGET bounds a night
# rather than each wake. It is container-local: a restart forgets it and sweeps
# again at once, which costs at most one extra sweep.
marker=${TMPDIR:-/tmp}/fixity-window

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

# The UTC date the current window opened on. One that crosses midnight opened
# the day before while the hour is still short of its end.
window_opened() {
  if (( start > end && 10#$(date -u +%H) < end )); then
    date -u -d '-1 day' +%F
  else
    date -u +%F
  fi
}

log "started as $(id -un); window ${start}:00-${end}:00 UTC; wakes every ${interval}s; cycle ${FIXITY_CYCLE:-default}; roots ${OCFL_ROOTS}"

for root in ${OCFL_ROOTS//:/ }; do
  if touch "$root/.fixity-write-probe" 2>/dev/null; then
    rm -f "$root/.fixity-write-probe"
    log "WARNING: $root is writable; mount it read-only"
  fi
done

limits=()
[[ -n "${FIXITY_BUDGET:-}" ]] && limits+=(--budget "$FIXITY_BUDGET")
[[ -n "${FIXITY_CYCLE:-}" ]] && limits+=(--cycle "$FIXITY_CYCLE")

# Never returns: a service that exits is restarted at once, so a one-shot
# script would run in a tight loop. Priority is set here because a host-level
# setting never reaches a process dockerd starts. Only exit 0 closes the
# window; a refused or unreachable Atlas exits non-zero and the next wake
# retries.
while true; do
  if in_window; then
    window=$(window_opened)
    if [[ "$(cat "$marker" 2>/dev/null)" != "$window" ]]; then
      ionice -c3 nice -n19 "$sweep" --until "$(printf '%02d:00' "$end")" \
        --report-to "${ATLAS_URL:?ATLAS_URL must be set}" "${limits[@]}"
      status=$?
      log "sweep exited $status"
      if (( status == 0 )); then
        printf '%s\n' "$window" > "$marker"
        log "window opened $window is done; next sweep in the next window"
      fi
    fi
  fi
  sleep "$interval"
done
