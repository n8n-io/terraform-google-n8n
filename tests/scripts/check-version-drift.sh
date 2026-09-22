#!/usr/bin/env bash
# Reports every version pin this module makes that has fallen behind its
# upstream source, cross-referenced against docs/versioning.md's inventory.
# Reports only: never rewrites a pin, never fails a build on drift alone
# (see the weekly version-drift.yml workflow, which files/updates a
# tracking issue rather than gating a PR).
#
# Every lookup that cannot complete (network failure, API shape change,
# missing tool) is reported as an explicit ERROR, distinct from "no drift
# found" - a lookup that silently no-ops would be worse than not checking
# at all, since it would look identical to "up to date".
#
# Requires: curl, python3, helm (for the KEDA chart repo lookup) on PATH.
# No Google Cloud credentials needed.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck source=lib/tf-defaults.sh
source tests/scripts/lib/tf-defaults.sh

drift_count=0
error_count=0

report_drift() {
  echo "DRIFT: $1 pinned at $2, latest is $3"
  drift_count=$((drift_count + 1))
}

report_ok() {
  echo "OK:    $1 pinned at $2 (latest)"
}

report_error() {
  echo "ERROR: $1: $2" >&2
  error_count=$((error_count + 1))
}

# ── Terraform providers (registry.terraform.io) ───────────────────────────

check_provider() {
  local display="$1" namespace="$2" name="$3" current
  current="$(tf_provider_version versions.tf "$name")" || {
    report_error "$display" "could not read current constraint from versions.tf"
    return
  }
  # tf_provider_version returns the constraint string (e.g. "~> 3.0"); take
  # the numeric part for the comparison message, the API call needs none of it.
  local latest
  latest="$(curl -sf "https://registry.terraform.io/v1/providers/${namespace}/${name}/versions" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
versions = [v['version'] for v in data['versions'] if '-' not in v['version']]
def key(v):
    return tuple(int(x) for x in v.split('.'))
print(sorted(versions, key=key)[-1])
" 2>/dev/null)" || {
    report_error "$display" "registry.terraform.io lookup failed"
    return
  }
  if [ -z "$latest" ]; then
    report_error "$display" "registry.terraform.io returned no usable version list"
    return
  fi
  if [[ "$current" == *"$latest"* ]]; then
    report_ok "$display" "$current"
  else
    report_drift "$display" "$current" "$latest"
  fi
}

check_provider "google"       "hashicorp"     "google"
check_provider "google-beta"  "hashicorp"     "google-beta"
check_provider "kubernetes"   "hashicorp"     "kubernetes"
check_provider "helm"         "hashicorp"     "helm"
check_provider "kubectl"      "gavinbunney"   "kubectl"
check_provider "tls"          "hashicorp"     "tls"
check_provider "random"       "hashicorp"     "random"
check_provider "time"         "hashicorp"     "time"

# ── n8n Helm chart (GHCR OCI tags, anonymous read) ─────────────────────────

check_n8n_chart() {
  local current latest token
  current="$(tf_var_default variables.tf n8n_chart_version)" || {
    report_error "n8n chart" "could not read n8n_chart_version default"
    return
  }
  token="$(curl -sf "https://ghcr.io/token?scope=repository:n8n-io/n8n-helm-chart/n8n:pull&service=ghcr.io" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)"
  if [ -z "$token" ]; then
    report_error "n8n chart" "ghcr.io anonymous token request failed"
    return
  fi
  latest="$(curl -sf -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/n8n-io/n8n-helm-chart/n8n/tags/list" \
    | python3 -c "
import json, sys
tags = json.load(sys.stdin)['tags']
# Exclude prereleases (e.g. '1.11.0-preview.workerpools.1'); a prerelease is
# never the 'latest numbered release' this check reports against.
numbered = [t for t in tags if '-' not in t]
def key(v):
    return tuple(int(x) for x in v.split('.'))
print(sorted(numbered, key=key)[-1])
" 2>/dev/null)"
  if [ -z "$latest" ]; then
    report_error "n8n chart" "ghcr.io tag list lookup failed"
    return
  fi
  if [ "$current" = "$latest" ]; then
    report_ok "n8n chart" "$current"
  else
    report_drift "n8n chart" "$current" "$latest"
  fi
}
check_n8n_chart

# ── KEDA Helm chart (kedacore.github.io/charts) ────────────────────────────

check_keda_chart() {
  local current latest
  current="$(tf_var_default variables.tf keda_chart_version)" || {
    report_error "KEDA chart" "could not read keda_chart_version default"
    return
  }
  if ! command -v helm >/dev/null 2>&1; then
    report_error "KEDA chart" "helm is not on PATH"
    return
  fi
  helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1
  if ! helm repo update kedacore >/dev/null 2>&1; then
    report_error "KEDA chart" "helm repo update kedacore failed (network?)"
    return
  fi
  latest="$(helm search repo kedacore/keda --versions -o json 2>/dev/null \
    | python3 -c "
import json, sys
entries = json.load(sys.stdin)
def key(v):
    return tuple(int(x) for x in v.split('.'))
print(sorted((e['version'] for e in entries), key=key)[-1])
" 2>/dev/null)"
  if [ -z "$latest" ]; then
    report_error "KEDA chart" "helm search repo returned no versions"
    return
  fi
  if [ "$current" = "$latest" ]; then
    report_ok "KEDA chart" "$current"
  else
    report_drift "KEDA chart" "$current" "$latest"
  fi
}
check_keda_chart

# ── GKE release channel supported versions ─────────────────────────────────
# This module tracks a release channel (gke_release_channel, default
# REGULAR), not a fixed Kubernetes minor the way EKS's kubernetes_version
# does, so there is nothing numeric to diff here. Report the configured
# channel as informational only; a channel change is a deliberate decision,
# not something this script can flag as "behind".

current_channel="$(tf_var_default variables_gcp.tf gke_release_channel 2>/dev/null || echo "REGULAR")"
echo "INFO:  GKE release channel is ${current_channel} (no fixed Kubernetes minor to diff; see docs/versioning.md)"

# ── Summary ──────────────────────────────────────────────────────────────

echo
echo "check-version-drift.sh: ${drift_count} pin(s) behind upstream, ${error_count} lookup(s) failed"

if [ "$error_count" -gt 0 ]; then
  exit 2
fi
exit 0
