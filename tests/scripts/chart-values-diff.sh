#!/usr/bin/env bash
# Diffs the pinned n8n chart's values.yaml against a candidate version, so
# the manual "did anything change" step of a version-currency pickup is one
# command instead of two remembered `helm show values` invocations plus a
# manual diff. Never writes or bumps n8n_chart_version; purely informational.
#
# Usage: tests/scripts/chart-values-diff.sh <candidate-version>
#   e.g. tests/scripts/chart-values-diff.sh 1.12.0
#
# Exit codes:
#   0  both `helm show values` calls succeeded and diff ran (regardless of
#      whether a diff was found)
#   1  bad usage, missing tool, or a `helm show values` call failed (a
#      network/registry issue, or a candidate version that doesn't exist)
#   diff's own exit code is not propagated: a real values.yaml diff is the
#   expected, successful outcome of this script, not a failure.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck source=lib/tf-defaults.sh
source tests/scripts/lib/tf-defaults.sh

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: tests/scripts/chart-values-diff.sh <candidate-version>" >&2
  exit 1
fi
candidate_version="$1"

if ! command -v helm >/dev/null 2>&1; then
  echo "chart-values-diff.sh: helm is not on PATH" >&2
  exit 1
fi

pinned_version="$(tf_var_default variables.tf n8n_chart_version)" || {
  echo "chart-values-diff.sh: could not read n8n_chart_version default from variables.tf" >&2
  exit 1
}
chart_repository="$(tf_var_default variables.tf n8n_chart_repository)" || chart_repository="oci://ghcr.io/n8n-io/n8n-helm-chart"

pinned_file="$(mktemp)"
candidate_file="$(mktemp)"
trap 'rm -f "$pinned_file" "$candidate_file"' EXIT

echo "==> helm show values ${chart_repository}/n8n --version ${pinned_version}"
if ! helm show values "${chart_repository}/n8n" --version "$pinned_version" >"$pinned_file" 2>&1; then
  echo "chart-values-diff.sh: helm show values failed for the pinned version (${pinned_version})" >&2
  echo "  see output above (registry unreachable, or bad chart pin)" >&2
  exit 1
fi

echo "==> helm show values ${chart_repository}/n8n --version ${candidate_version}"
if ! helm show values "${chart_repository}/n8n" --version "$candidate_version" >"$candidate_file" 2>&1; then
  echo "chart-values-diff.sh: helm show values failed for the candidate version (${candidate_version})" >&2
  echo "  see output above (network issue, or that version does not exist)" >&2
  exit 1
fi

echo "==> diff: pinned (${pinned_version}) vs candidate (${candidate_version})"
diff -u "$pinned_file" "$candidate_file" || true

echo
echo "chart-values-diff.sh: both helm show values calls succeeded"
