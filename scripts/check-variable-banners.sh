#!/usr/bin/env bash
# check-variable-banners.sh — every variable/output block in variables.tf,
# variables_gcp.tf, and outputs.tf must sit under a "# ── Section ──" banner
# comment (see AGENTS.md, "Clear documentation"). Catches two drift patterns:
#
#   1. A block appended with no banner above it at all.
#   2. A banner-like comment that doesn't match the established format
#      (wrong dashes, missing padding, typo'd style).
#
# What this script deliberately does NOT check: whether a variable was filed
# under the *correct* banner for its meaning (e.g. a new toggle landing in
# "Execution settings" vs "Task runners"). That judgment call still needs a
# human/CODEOWNERS review — this only guarantees the convention itself can't
# silently rot to "no sections at all".

set -euo pipefail

# The banner regexes below match the multibyte "─" (U+2500) used in
# variables.tf/variables_gcp.tf/outputs.tf. Bash's [[ =~ ]] only resolves that
# against file content under a UTF-8 locale; a C/POSIX locale (the default in
# minimal shells and containers, and whatever LC_ALL/LANG a CI image sets)
# makes every real banner fail the strict-format check. Leave an
# already-UTF-8 locale alone; otherwise force C.UTF-8, the most widely
# available UTF-8 locale, via LC_ALL since it — not a scoped LC_CTYPE — is
# what a non-UTF-8 LC_ALL in the environment would otherwise override.
effective_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case "$effective_locale" in
  *.[Uu][Tt][Ff]-8 | *.[Uu][Tt][Ff]8) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FILES=(variables.tf variables_gcp.tf outputs.tf)
# Keep in lockstep with the actual banner order in each file. Run this
# script and read its failure output after adding/renaming/reordering a
# section; do not hand-maintain this list from memory.
VARIABLES_BANNERS=("Foundation inputs" "Credential overwrites" "Existing core Secret (n8n_kube_namespace)" "Ingress ownership" "n8n chart" "Controllers submodule (modules/controllers)" "Application images" "Caller-managed volumes" "n8n resource requests and limits" "Execution settings" "Execution-save policy" "Graceful shutdown" "Task runners" "V8 heap ceiling" "Community registry and security-related runtime controls" "Pod DNS" "Cloud SQL PostgreSQL" "Execution data storage" "HPA: main pods" "HPA: webhook processor pods" "License shutdown behavior" "Observability" "Community packages" "KEDA: worker pods" "Worker pools (EARLY ALPHA)" "External Secrets and Google Secret Manager")
VARIABLES_GCP_BANNERS=("Project and region" "Networking ownership (infrastructure-ownership)" "Private Service Access ownership" "Networking (VPC-native)" "Cloud SQL" "Cloud SQL backup and query-logging tuning (managed instance only)" "Cloud SQL restore source (managed instance only)" "Cloud SQL customer-managed encryption (Cloud KMS)" "Shared Cloud KMS key ring" "Memorystore" "Opt-in Memorystore RDB persistence (managed instance only)" "Opt-in Redis exporter (observability.tf)" "Memorystore customer-managed encryption (Cloud KMS)" "GCS bucket ownership" "GCS customer-managed encryption (Cloud KMS)" "GCS binary storage" "BYO / pre-existing HMAC key" "Workload Identity" "TLS" "DNS (Google Cloud DNS , base/default path)" "Additional ingress hosts and annotations" "Managed-ingress security controls" "GKE ownership" "GKE cluster + node pool")
OUTPUT_BANNERS=("App DNS" "Secrets (retrieve with terraform output -raw <name>)" "Infrastructure (ownership-neutral effective coordinates)" "Cluster (wire the kubernetes/helm/kubectl providers in your root/example)" "Service and route contract (build a customer-managed ingress from these)")
BANNER_LOOSE_RE='^#[[:space:]]+[─—-]'
BANNER_STRICT_RE='^# ── (.+) ─{2,}$'
BLOCK_RE='^(variable|output) "'

fail=0

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "check-variable-banners: $file not found" >&2
    fail=1
    continue
  fi

  banner=""
  banners=()
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ $BANNER_LOOSE_RE ]]; then
      if [[ ! "$line" =~ $BANNER_STRICT_RE ]]; then
        echo "$file:$lineno: malformed banner (expected '# ── Section Name ──...──'): $line" >&2
        fail=1
      else
        banner="${BASH_REMATCH[1]}"
        banners+=("$banner")
      fi
    elif [[ "$line" =~ $BLOCK_RE ]]; then
      if [[ -z "$banner" ]]; then
        echo "$file:$lineno: no preceding '# ── Section ──' banner for: $line" >&2
        fail=1
      fi
    fi
  done < "$file"

  case "$file" in
    variables.tf) expected=("${VARIABLES_BANNERS[@]}") ;;
    variables_gcp.tf) expected=("${VARIABLES_GCP_BANNERS[@]}") ;;
    outputs.tf) expected=("${OUTPUT_BANNERS[@]}") ;;
  esac
  banners_match=true
  if [[ "${#banners[@]}" -ne "${#expected[@]}" ]]; then
    banners_match=false
  else
    for ((i = 0; i < ${#expected[@]}; i++)); do
      if [[ "${banners[$i]}" != "${expected[$i]}" ]]; then
        banners_match=false
        break
      fi
    done
  fi
  if [[ "$banners_match" != true ]]; then
    echo "$file: section banners are missing, renamed, or out of order" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-variable-banners: FAILED" >&2
  exit 1
fi

echo "check-variable-banners: OK (${FILES[*]})"
