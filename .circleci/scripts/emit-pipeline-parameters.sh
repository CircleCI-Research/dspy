#!/usr/bin/env bash
#
# Emit the pipeline parameters consumed by .circleci/continue-config.yml.
#
# This is the CircleCI stand-in for two GitHub Actions features:
#   * per-workflow `on.<event>.paths` filters -- GitHub decides *whether a
#     workflow runs at all* from the changed path set. CircleCI always starts
#     the pipeline, so the decision is made here and passed downstream as
#     boolean pipeline parameters gating each workflow.
#   * `on.workflow_dispatch` -- replaced by API-triggered pipeline parameters
#     (FORCE_PRE_COMMIT / FORCE_DEPENDENCY_RANGE).
#
# Usage: emit-pipeline-parameters.sh [OUTPUT_JSON]
#
# Environment:
#   BASE_REVISION           branch to diff against (default: main)
#   FORCE_PRE_COMMIT        "true" to run only the pre-commit workflow
#   FORCE_DEPENDENCY_RANGE  "true" to force the dependency-range workflow
#   CIRCLE_BRANCH           provided by CircleCI
#   CHANGED_FILES_FILE      debug/test seam. When set to a readable file, the
#                           changed path list is read from it instead of being
#                           derived with changed-files.sh. Not set in CI.
#
# The parameter names written here MUST match the `parameters:` block of
# .circleci/continue-config.yml exactly. Nothing in the CircleCI toolchain
# checks that; see the "contract" test in the accompanying report.
#
set -euo pipefail

out="${1:-/tmp/pipeline-parameters.json}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${BASE_REVISION:=main}"
: "${FORCE_PRE_COMMIT:=false}"
: "${FORCE_DEPENDENCY_RANGE:=false}"
: "${CIRCLE_BRANCH:=}"

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'emit-pipeline-parameters.sh: %s is required but not on PATH\n' "$tool" >&2
    exit 1
  fi
done

if [ -n "${CHANGED_FILES_FILE:-}" ] && [ -r "${CHANGED_FILES_FILE}" ]; then
  changed="$(cat "${CHANGED_FILES_FILE}")"
else
  changed="$("${script_dir}/changed-files.sh" "$BASE_REVISION")"
fi

printf 'Base revision: %s\n' "$BASE_REVISION"
printf 'Branch: %s\n' "${CIRCLE_BRANCH:-<unknown>}"
printf -- '--- changed paths ---\n%s\n---------------------\n' "$changed"

# True when this pipeline is running on the base branch itself. GitHub's
# docs-push.yml gates its docs *build* on `github.event_name == 'pull_request'`,
# and dependency-range.yml only path-triggers on pull_request -- neither runs
# from a push to main.
on_base_branch=false
if [ -n "$CIRCLE_BRANCH" ] && [ "$CIRCLE_BRANCH" = "$BASE_REVISION" ]; then
  on_base_branch=true
fi

changed_matches() {
  printf '%s\n' "$changed" | grep -Eq "$1"
}

# run_tests.yml has no `paths:` filter: it runs on every push to main and every
# pull request. So core stays on unconditionally, except for a manual
# pre-commit dispatch, which in GitHub triggers precommits_check.yml alone.
run_core=true
run_docs=false
run_deps=false
run_pre_commit=false

if [ "$FORCE_PRE_COMMIT" = "true" ]; then
  run_pre_commit=true
  run_core=false
elif [ "$on_base_branch" = false ]; then
  # docs-push.yml: paths: ["docs/**"]
  if changed_matches '^docs/'; then
    run_docs=true
  fi
  # dependency-range.yml: paths: [pyproject.toml, uv.lock,
  # .github/workflows/dependency-range.yml]. The third entry is the workflow
  # definition itself; its CircleCI counterpart is continue-config.yml.
  if changed_matches '^(pyproject\.toml|uv\.lock|\.circleci/continue-config\.yml)$'; then
    run_deps=true
  fi
fi

# dependency-range.yml also has `schedule:` and `workflow_dispatch:` triggers,
# which reach main. Those bypass the branch gate above.
if [ "$FORCE_DEPENDENCY_RANGE" = "true" ]; then
  run_deps=true
fi

jq -n \
  --argjson runCore "$run_core" \
  --argjson runDocs "$run_docs" \
  --argjson runDeps "$run_deps" \
  --argjson runPreCommit "$run_pre_commit" \
  --arg baseRevision "$BASE_REVISION" \
  '{
     "run-core": $runCore,
     "run-docs": $runDocs,
     "run-deps": $runDeps,
     "run-pre-commit": $runPreCommit,
     "base-revision": $baseRevision
   }' > "$out"

printf 'Wrote %s:\n' "$out"
cat "$out"
