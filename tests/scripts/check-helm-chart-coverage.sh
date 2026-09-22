#!/usr/bin/env bash
# Fails when docs/helm-chart-coverage.md drifts from reality: its declared
# chart version disagreeing with variables.tf's n8n_chart_version default,
# or the pinned chart's values.yaml gaining a top-level key the doc never
# mentions. Catches the exact gap a first run of this class of check found
# upstream: nameOverride, fullnameOverride, and top-level replicaCount were
# never in a coverage table at all.
#
# Requires: helm on PATH. No credentials: pulls the pinned chart from the
# public OCI registry this module already uses by default.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=lib/tf-defaults.sh
source tests/scripts/lib/tf-defaults.sh

COVERAGE_DOC="docs/helm-chart-coverage.md"

if ! command -v helm >/dev/null 2>&1; then
  echo "check-helm-chart-coverage.sh: helm is not on PATH" >&2
  exit 1
fi

pinned_version="$(tf_var_default variables.tf n8n_chart_version)" || {
  echo "check-helm-chart-coverage.sh: could not read n8n_chart_version default from variables.tf" >&2
  exit 1
}

declared_version="$(python3 -c "
import re
with open('${COVERAGE_DOC}') as f:
    text = f.read()
m = re.search(r'default:\s*\*\*([0-9][0-9A-Za-z.\-+]*)\*\*', text)
print(m.group(1) if m else '')
")"

if [ -z "$declared_version" ]; then
  echo "check-helm-chart-coverage.sh: could not find a declared chart version in ${COVERAGE_DOC}" >&2
  echo "expected a line matching: (n8n_chart_version default: **X.Y.Z**, ...)" >&2
  exit 1
fi

status=0

if [ "$declared_version" != "$pinned_version" ]; then
  echo "check-helm-chart-coverage.sh: ${COVERAGE_DOC} declares chart version ${declared_version}, but variables.tf's n8n_chart_version default is ${pinned_version}. Update the doc." >&2
  status=1
fi

chart_repository="$(tf_var_default variables.tf n8n_chart_repository)" || chart_repository="oci://ghcr.io/n8n-io/n8n-helm-chart"

values_file="$(mktemp)"
trap 'rm -f "$values_file"' EXIT
if ! helm show values "${chart_repository}/n8n" --version "$pinned_version" >"$values_file" 2>/dev/null; then
  echo "check-helm-chart-coverage.sh: helm show values failed for ${chart_repository}/n8n --version ${pinned_version}" >&2
  exit 1
fi

# Top-level keys are lines with no leading whitespace, a colon, and not a
# comment - the same shape values.yaml uses throughout this chart.
chart_keys="$(python3 -c "
import sys
keys = []
with open('${values_file}') as f:
    for line in f:
        if line.strip() and not line.startswith((' ', '\t', '#')) and ':' in line:
            keys.append(line.split(':', 1)[0].strip())
print('\n'.join(keys))
")"

missing=()
while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! python3 -c "
import re
import sys
with open('${COVERAGE_DOC}') as f:
    text = f.read()
sys.exit(0 if re.search(r'\|\s*\`' + re.escape(sys.argv[1]) + r'\`\s*\|', text) else 1)
" "$key"; then
    missing+=("$key")
  fi
done <<<"$chart_keys"

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-helm-chart-coverage.sh: ${COVERAGE_DOC} is missing a row for: ${missing[*]}" >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "check-helm-chart-coverage.sh: ${COVERAGE_DOC} matches chart ${pinned_version}'s top-level values.yaml keys"
