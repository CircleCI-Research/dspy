#!/usr/bin/env bash
#
# Emulate Slashgear/action-check-pr-title, which has no CircleCI counterpart:
# CircleCI never receives the pull request title, only (sometimes) its URL.
#
# The title is fetched from the GitHub REST API and matched with Python's `re`
# rather than grep -E, because the upstream action evaluates the pattern as a
# JavaScript RegExp -- `\w`, `\s` and `{1}` are not portable across grep
# implementations but behave identically in Python.
#
# Environment:
#   TITLE_REGEXP   required. Pattern the PR title must match.
#   GITHUB_TOKEN   required when a pull request is detected. Needs `pull:read`
#                  on this repository. Add it as a CircleCI project env var or
#                  context.
#   CIRCLE_PULL_REQUEST, CIRCLE_PROJECT_USERNAME, CIRCLE_PROJECT_REPONAME
#                  provided by CircleCI.
#
set -euo pipefail

if [ -z "${TITLE_REGEXP:-}" ]; then
  printf 'pr-title-check.sh: TITLE_REGEXP must be set\n' >&2
  exit 1
fi

pr_url="${CIRCLE_PULL_REQUEST:-}"

if [ -z "$pr_url" ]; then
  # Mirrors GitHub, where this job only exists in a pull request context.
  # CircleCI does not populate CIRCLE_PULL_REQUEST for every same-repo PR, so a
  # missing value is treated as "not a PR" rather than as a failure.
  printf 'No pull request associated with this pipeline; skipping PR title check.\n'
  exit 0
fi

pr_number="${pr_url##*/}"
case "$pr_number" in
  ''|*[!0-9]*)
    printf 'pr-title-check.sh: cannot parse a PR number out of %s\n' "$pr_url" >&2
    exit 1
    ;;
esac

if [ -z "${GITHUB_TOKEN:-}" ]; then
  printf 'pr-title-check.sh: GITHUB_TOKEN is required to read the title of PR #%s\n' "$pr_number" >&2
  printf 'Set it as a CircleCI project environment variable or attach a context that provides it.\n' >&2
  exit 1
fi

for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'pr-title-check.sh: %s is required but not on PATH\n' "$tool" >&2
    exit 1
  fi
done

owner="${CIRCLE_PROJECT_USERNAME:?CIRCLE_PROJECT_USERNAME is not set}"
repo="${CIRCLE_PROJECT_REPONAME:?CIRCLE_PROJECT_REPONAME is not set}"
api="https://api.github.com/repos/${owner}/${repo}/pulls/${pr_number}"

response="$(curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$api")"

title="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"

printf 'Pull request #%s title: %s\n' "$pr_number" "$title"

PR_TITLE="$title" python3 - <<'PY'
import os
import re
import sys

pattern = os.environ["TITLE_REGEXP"]
title = os.environ["PR_TITLE"]

if re.search(pattern, title):
    print("PR title matches the required pattern.")
    sys.exit(0)

print(f"PR title does not match the required pattern.\n  title:   {title}\n  pattern: {pattern}", file=sys.stderr)
sys.exit(1)
PY
