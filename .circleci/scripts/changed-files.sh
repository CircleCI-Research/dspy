#!/usr/bin/env bash
#
# Print the repository-relative paths changed by this pipeline, one per line.
#
# Why this exists: CircleCI has no equivalent of either
#   * GitHub Actions' `on.pull_request.paths` / `on.push.paths` trigger filters
#     (used by docs-push.yml and dependency-range.yml), or
#   * the `jitterbit/get-changed-files` action (used by precommits_check.yml).
# Both are emulated by diffing against the base branch here.
#
# Usage:
#   changed-files.sh [BASE_REVISION] [--existing]
#
#   BASE_REVISION  branch to diff against. Defaults to $BASE_REVISION, then "main".
#   --existing     only print paths that still exist in the working tree.
#                  Required when feeding the list to `pre-commit run --files`,
#                  which errors on paths it cannot open.
#
# Behaviour notes:
#   * On a topic branch the range is `merge-base(base, HEAD)..HEAD`, matching
#     what GitHub reports for a pull request.
#   * When HEAD *is* the base branch tip (a push to main), there is no range to
#     compare, so the range becomes `HEAD~1..HEAD` -- what that push changed.
#   * A root commit with no parent prints nothing and exits 0.
#
set -euo pipefail

base=""
existing_only=false

for arg in "$@"; do
  case "$arg" in
    --existing) existing_only=true ;;
    -*) printf 'changed-files.sh: unknown option %s\n' "$arg" >&2; exit 2 ;;
    *) base="$arg" ;;
  esac
done

if [ -z "$base" ]; then
  base="${BASE_REVISION:-main}"
fi

if ! command -v git >/dev/null 2>&1; then
  printf 'changed-files.sh: git is required but not on PATH\n' >&2
  exit 1
fi

# Resolve the base branch to a commit. Prefer the remote-tracking ref, because
# in CI the local branch of the same name usually does not exist.
resolve_base() {
  local ref
  for ref in "refs/remotes/origin/${base}" "refs/heads/${base}" "${base}"; do
    if git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
      git rev-parse "${ref}^{commit}"
      return 0
    fi
  done
  return 1
}

if ! base_sha="$(resolve_base)"; then
  # Shallow clone that does not contain the base branch yet: fetch just its tip.
  git fetch --quiet --no-tags --depth=100 origin \
    "+refs/heads/${base}:refs/remotes/origin/${base}" 2>/dev/null || true
  if ! base_sha="$(resolve_base)"; then
    printf 'changed-files.sh: cannot resolve base revision %s\n' "$base" >&2
    exit 1
  fi
fi

head_sha="$(git rev-parse HEAD)"

if [ "$base_sha" = "$head_sha" ]; then
  if ! parent_sha="$(git rev-parse --verify --quiet 'HEAD^{commit}~1')"; then
    # Root commit: nothing to diff against.
    exit 0
  fi
  range="${parent_sha}..${head_sha}"
else
  if ! merge_base="$(git merge-base "$base_sha" "$head_sha" 2>/dev/null)"; then
    # Unrelated histories (e.g. a truncated clone): compare tips directly.
    merge_base="$base_sha"
  fi
  range="${merge_base}..${head_sha}"
fi

if [ "$existing_only" = true ]; then
  git diff --name-only "$range" | while IFS= read -r path; do
    [ -e "$path" ] && printf '%s\n' "$path"
  done
else
  git diff --name-only "$range"
fi
