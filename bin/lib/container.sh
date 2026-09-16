# shellcheck shell=bash
#
# Works out where this checkout appears INSIDE the web container, which is not
# where it appears on the host. The main checkout is bind-mounted onto
# /home/atlas/web, so its host path does not resolve in there at all; a worktree
# is reachable only because the gitignored docker-compose.override.yml mounts
# the worktrees parent at the same path on both sides.
#
# Passing the host path for the main checkout is what `docker exec -w` rejects
# with:
#
#   chdir to cwd ("/home/nakatomi/projects/atlas") ... no such file or directory
#
# Sourced by bin/spec and bin/parallel-spec so the two cannot drift apart.

WEB_CONTAINER="${WEB_CONTAINER:-atlas-web-1}"

container_init() {
  if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "not inside a git repository." >&2
    return 1
  fi
  # git rev-parse --git-common-dir answers RELATIVE from the main checkout
  # (".git") and ABSOLUTE from a worktree, so it has to be normalised before
  # anything joins paths with it. Left relative, MAIN_ROOT becomes "." and every
  # path below silently depends on the caller's cwd.
  local common
  common="$(cd "$REPO_ROOT" && git rev-parse --git-common-dir)"
  [[ "$common" != /* ]] && common="$REPO_ROOT/$common"
  MAIN_ROOT="$(cd "$(dirname "$common")" && pwd)"

  if [[ "$REPO_ROOT" == "$MAIN_ROOT" ]]; then
    CONTAINER_ROOT=/home/atlas/web
  else
    CONTAINER_ROOT="$REPO_ROOT"
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$WEB_CONTAINER"; then
    echo "web container '$WEB_CONTAINER' is not running — bring the stack up first" >&2
    return 1
  fi
  return 0
}
