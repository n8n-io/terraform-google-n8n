#!/usr/bin/env bash
# smoke-test.sh, post-deployment smoke test for terraform-google-n8n.
#
# This module deploys the multi-main topology (multiple main + worker +
# webhook-processor pods, PostgreSQL, Redis, KEDA). The script auto-detects
# the topology by probing the namespace; for this module that is always the
# multi-main path, main/worker/webhook-processor pod health, queue mode,
# Redis connectivity, KEDA ScaledObject, HTTPS, API, and end-to-end execution.
#
# It also runs a set of customer-managed infrastructure checks that apply
# the same way regardless of which layers are module-managed vs
# customer-managed (see docs/customer-managed-infrastructure.md): Redis TLS
# and AUTH, GCS object-storage access, the well-known referenced Secrets,
# KEDA ScaledObject/TriggerAuthentication reads, ingress route correctness
# for every n8n_webhook_route_prefixes entry, and duplicate customer-managed
# resource detection (namespace, KEDA operator, main Service).
#
# Usage:
#   # Run from the example directory, outputs are read automatically:
#   cd examples/small
#   ../../tests/scripts/smoke-test.sh
#
#   # Or point at a Terraform directory explicitly:
#   TERRAFORM_DIR=examples/small ./tests/scripts/smoke-test.sh
#
#   # Override any value by setting it in .env (next to this script,
#   # or next to terraform.tfstate):
#   cp tests/scripts/.env.example tests/scripts/.env
#   # edit .env, then run the script.
#
#   # Force mode (skip auto-detection):
#   DEPLOY_MODE=multi ./tests/scripts/smoke-test.sh
#
# Priority: .env explicit values > Terraform outputs > built-in defaults.

set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────
# Look for .env in (1) the script's own directory, then (2) the current working
# directory (TERRAFORM_DIR). This lets you keep secrets next to the Terraform
# files rather than alongside the script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _env_candidate in "$SCRIPT_DIR/.env" "$(pwd)/.env"; do
  if [[ -f "$_env_candidate" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$_env_candidate"; set +a
    break
  fi
done

# ── Read from Terraform outputs ───────────────────────────────────────────────
# Default TERRAFORM_DIR to the current working directory so running the script
# from inside a terraform directory just works.

TERRAFORM_DIR="${TERRAFORM_DIR:-$(pwd)}"

if command -v terraform &>/dev/null && [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
  echo -e "\033[0;36m↳\033[0m  Reading values from Terraform state in: $TERRAFORM_DIR"

  tf_namespace=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_kube_namespace 2>/dev/null || true)
  tf_n8n_url=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_url 2>/dev/null || true)
  tf_kubectl_cmd=$(terraform -chdir="$TERRAFORM_DIR" output -raw kubectl_config_command 2>/dev/null || true)

  # Ownership-neutral effective coordinates, used by the customer-managed
  # infrastructure checks below. Each resolves to the real value regardless
  # of whether the layer is module-managed or customer-managed (or empty on
  # an older module version / apply that predates these outputs, in which
  # case the corresponding check is skipped).
  tf_redis_host=$(terraform -chdir="$TERRAFORM_DIR" output -raw redis_host 2>/dev/null || true)
  tf_redis_tls_enabled=$(terraform -chdir="$TERRAFORM_DIR" output -raw redis_tls_enabled 2>/dev/null || true)
  tf_gcs_bucket_name=$(terraform -chdir="$TERRAFORM_DIR" output -raw gcs_bucket_name 2>/dev/null || true)
  tf_main_service=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_main_service_name 2>/dev/null || true)
  tf_webhook_service=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_webhook_service_name 2>/dev/null || true)
  tf_service_port=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_service_port 2>/dev/null || true)
  tf_webhook_route_prefixes=$(terraform -chdir="$TERRAFORM_DIR" output -json n8n_webhook_route_prefixes 2>/dev/null || true)
  tf_ingress_hosts=$(terraform -chdir="$TERRAFORM_DIR" output -json n8n_ingress_hosts 2>/dev/null || true)
  tf_redis_exporter_service=$(terraform -chdir="$TERRAFORM_DIR" output -raw redis_exporter_service_name 2>/dev/null || true)

  # Only apply if not already set via .env / environment
  NAMESPACE="${NAMESPACE:-$tf_namespace}"
  N8N_URL="${N8N_URL:-$tf_n8n_url}"
  REDIS_HOST="${REDIS_HOST:-$tf_redis_host}"
  REDIS_TLS_ENABLED="${REDIS_TLS_ENABLED:-$tf_redis_tls_enabled}"
  GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-$tf_gcs_bucket_name}"
  N8N_MAIN_SERVICE="${N8N_MAIN_SERVICE:-$tf_main_service}"
  N8N_WEBHOOK_SERVICE="${N8N_WEBHOOK_SERVICE:-$tf_webhook_service}"
  N8N_SERVICE_PORT="${N8N_SERVICE_PORT:-$tf_service_port}"
  N8N_WEBHOOK_ROUTE_PREFIXES_JSON="${N8N_WEBHOOK_ROUTE_PREFIXES_JSON:-$tf_webhook_route_prefixes}"
  N8N_INGRESS_HOSTS_JSON="${N8N_INGRESS_HOSTS_JSON:-$tf_ingress_hosts}"
  REDIS_EXPORTER_SERVICE="${REDIS_EXPORTER_SERVICE:-$tf_redis_exporter_service}"

  echo -e "\033[0;36m↳\033[0m  namespace = ${NAMESPACE:-<not found>}"
  echo -e "\033[0;36m↳\033[0m  n8n_url   = ${N8N_URL:-<not found>}"

  # Switch kubectl context to the cluster from this Terraform deployment.
  # Required when multiple clusters are configured, avoids running against
  # the wrong cluster if the context was last pointed elsewhere.
  #
  # Fail loudly if the switch does not work. Under `set -e` a silent failure
  # used to abort the script with no message; without `set -e` it would fall
  # through to whatever context happened to be current, which may be an
  # unrelated cluster. Both are worse than stopping here.
  if [[ -n "$tf_kubectl_cmd" ]]; then
    echo -e "\033[0;36m↳\033[0m  Switching kubectl context: $tf_kubectl_cmd"
    if ! _switch_output=$(eval "$tf_kubectl_cmd" 2>&1); then
      echo -e "\033[0;31mERROR: kubectl context switch failed:\033[0m" >&2
      echo "$_switch_output" | sed 's/^/    /' >&2
      echo "Re-authenticate first (for example: gcloud auth login), then re-run." >&2
      exit 1
    fi

    # Confirm the current context is the GKE one gcloud just wrote for this
    # cluster (gke_<project>_<location>_<cluster>) before any kubectl call.
    _expected_ctx=$(echo "$tf_kubectl_cmd" | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "get-credentials") name = $(i + 1)
        if ($i == "--region" || $i == "--zone" || $i == "--location") loc = $(i + 1)
        if ($i == "--project") proj = $(i + 1)
      }
      if (name != "" && loc != "" && proj != "") printf "gke_%s_%s_%s", proj, loc, name
    }')
    _current_ctx=$(kubectl config current-context 2>/dev/null || true)
    if [[ -n "$_expected_ctx" && "$_current_ctx" != "$_expected_ctx" ]]; then
      echo -e "\033[0;31mERROR: kubectl current-context is '$_current_ctx', expected '$_expected_ctx'. Refusing to run against another cluster.\033[0m" >&2
      exit 1
    fi
    echo -e "\033[0;36m↳\033[0m  kubectl context = ${_current_ctx}"
  fi

  echo ""
fi

# ── Configuration ─────────────────────────────────────────────────────────────

NAMESPACE="${NAMESPACE:-${N8N_NAMESPACE:-n8n}}"
N8N_URL="${N8N_URL:-}"
N8N_API_KEY="${N8N_API_KEY:-}"
DEPLOY_MODE="${DEPLOY_MODE:-}"        # set to 'single' or 'multi' to skip auto-detect

# Customer-managed infrastructure checks (below): each of these is populated
# from the module's ownership-neutral outputs when read from Terraform state
# (see above), and can be overridden directly via .env / environment for a
# deployment probed without Terraform state (e.g. a live cluster reached only
# via kubectl).
REDIS_HOST="${REDIS_HOST:-}"
REDIS_TLS_ENABLED="${REDIS_TLS_ENABLED:-}"
GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-}"
N8N_MAIN_SERVICE="${N8N_MAIN_SERVICE:-}"
N8N_WEBHOOK_SERVICE="${N8N_WEBHOOK_SERVICE:-}"
N8N_SERVICE_PORT="${N8N_SERVICE_PORT:-}"
N8N_WEBHOOK_ROUTE_PREFIXES_JSON="${N8N_WEBHOOK_ROUTE_PREFIXES_JSON:-}"
N8N_INGRESS_HOSTS_JSON="${N8N_INGRESS_HOSTS_JSON:-}"
REDIS_EXPORTER_SERVICE="${REDIS_EXPORTER_SERVICE:-}"

# Multi-mode optional load test settings
LOAD_TEST="${LOAD_TEST:-false}"
LOAD_REQUESTS="${LOAD_REQUESTS:-100}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-20}"
LOAD_SEED_JOBS="${LOAD_SEED_JOBS:-20}"   # jobs queued in phase 1 to trigger the autoscaler
SCALE_WAIT_SECS="${SCALE_WAIT_SECS:-180}"
LOAD_JOB_DURATION_SECS="${LOAD_JOB_DURATION_SECS:-10}"

# Expected minimum replica counts for multi-main deployments
MAIN_MIN=2
WORKER_MIN=1
WEBHOOK_MIN=2

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── State ─────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
WARN=0
SKIPPED=0

# ── Helpers ───────────────────────────────────────────────────────────────────

header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
pass()   { echo -e "  ${GREEN}✔${RESET}  $*"; PASS=$((PASS + 1)); }
fail()   { echo -e "  ${RED}✘${RESET}  $*"; FAIL=$((FAIL + 1)); }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $*"; WARN=$((WARN + 1)); }
skip()   { echo -e "  ${YELLOW}–${RESET}  $* ${YELLOW}(skipped)${RESET}"; SKIPPED=$((SKIPPED + 1)); }
info()   { echo -e "      ${CYAN}↳${RESET} $*"; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}ERROR: required command '$1' not found.${RESET}" >&2
    exit 1
  fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────

header "Preflight"

require_cmd kubectl
require_cmd curl

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach the cluster. Check your kubeconfig / credentials.${RESET}" >&2
  exit 1
fi
pass "kubectl cluster connectivity"

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  fail "Namespace '$NAMESPACE' does not exist"
  exit 1
fi
pass "Namespace '$NAMESPACE' exists"

if [[ -z "$N8N_URL" ]]; then
  warn "N8N_URL not set, HTTP and API tests will be skipped"
  warn "  Set N8N_URL=https://your-domain.com to enable them"
fi

if [[ -z "$N8N_API_KEY" ]]; then
  warn "N8N_API_KEY not set, workflow execution test will be skipped"
  warn "  Create one in n8n: Settings > API > Create API Key"
fi

# ── Deployment mode detection ─────────────────────────────────────────────────

header "Deployment Mode"

if [[ -n "$DEPLOY_MODE" ]]; then
  info "Mode forced via DEPLOY_MODE=$DEPLOY_MODE"
elif kubectl get deployment n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  DEPLOY_MODE="multi"
else
  DEPLOY_MODE="single"
fi

if [[ "$DEPLOY_MODE" == "multi" ]]; then
  pass "Multi-main deployment detected (n8n-worker present)"
  info "Checks: queue mode, HPA/KEDA, Redis, leader election"
else
  pass "Single-instance deployment detected"
  info "Checks: SQLite PVC, task runner sidecar, Python runner"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SINGLE-INSTANCE CHECKS
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$DEPLOY_MODE" == "single" ]]; then

# ── Pod health (single) ───────────────────────────────────────────────────────

header "Pod Health"

if ! kubectl get deployment n8n-main -n "$NAMESPACE" &>/dev/null; then
  fail "Deployment 'n8n-main' not found in namespace '$NAMESPACE'"
  echo -e "${RED}Cannot continue, no n8n deployment found.${RESET}" >&2
  exit 1
fi

ready=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
ready="${ready:-0}"
desired=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

if [[ "$ready" -eq "$desired" && "$ready" -gt 0 ]]; then
  pass "n8n-main pod: $ready/$desired ready"
else
  fail "n8n-main pod: $ready/$desired ready"
fi

# Surface any pods not in Running state
bad_pods=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=n8n" \
  --no-headers 2>/dev/null \
  | awk '{print $1, $3}' \
  | grep -v "Running\|Completed" || true)
if [[ -n "$bad_pods" ]]; then
  warn "Unhealthy pods detected:"
  while IFS= read -r line; do info "$line"; done <<< "$bad_pods"
fi

# Grab the running pod name for subsequent checks
N8N_POD=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=n8n" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$N8N_POD" ]]; then
  fail "Could not find a running n8n pod, remaining checks will be limited"
else
  info "Using pod: $N8N_POD"
fi

# ── SQLite PVC ────────────────────────────────────────────────────────────────

header "SQLite Persistent Volume"

pvc=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -i "n8n\|sqlite\|data" | head -3 || true)

if [[ -n "$pvc" ]]; then
  bound=$(echo "$pvc" | grep -c "Bound" || true)
  total=$(echo "$pvc" | wc -l | tr -d ' ')
  if [[ "$bound" -eq "$total" ]]; then
    pass "PVC(s) bound ($bound/$total)"
    while IFS= read -r line; do info "$line"; done <<< "$pvc"
  else
    fail "One or more PVCs not bound ($bound/$total)"
    while IFS= read -r line; do info "$line"; done <<< "$pvc"
  fi
else
  warn "No PVCs found matching n8n, SQLite data may not be persisted"
  info "Check: kubectl get pvc -n $NAMESPACE"
fi

# Verify the data directory is writable inside the running pod
if [[ -n "$N8N_POD" ]]; then
  data_dir=$(kubectl exec "$N8N_POD" -n "$NAMESPACE" -c n8n \
    -- printenv N8N_USER_FOLDER 2>/dev/null \
    || kubectl exec "$N8N_POD" -n "$NAMESPACE" -c n8n \
    -- printenv HOME 2>/dev/null || echo "")

  if [[ -n "$data_dir" ]]; then
    if kubectl exec "$N8N_POD" -n "$NAMESPACE" -c n8n \
        -- sh -c "test -w $data_dir" &>/dev/null; then
      pass "Data directory is writable: $data_dir"
    else
      warn "Data directory may not be writable: $data_dir"
    fi
  fi
fi

# ── Task runner sidecar (single) ──────────────────────────────────────────────
# Since chart 1.13.0 (n8n-hosting#179) the sidecar renders on worker pods only
# in queue mode, which this module always runs; main offloads manual
# executions to workers and starts no runner broker. Check the worker pod.

header "Task Runner Sidecar"

containers=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

info "Containers in n8n-worker pod spec: $containers"

main_containers=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")
if echo "$main_containers" | grep -qiE "runner"; then
  warn "Task runner sidecar present on n8n-main; expected on workers only since chart 1.13.0 (queue mode)"
else
  pass "No task runner sidecar on n8n-main (queue mode offloads execution to workers)"
fi

WORKER_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=worker" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if echo "$containers" | grep -qiE "runner"; then
  runner_container=$(echo "$containers" | tr ' ' '\n' | grep -iE "runner" | head -1)
  pass "Task runner sidecar found on n8n-worker: $runner_container"

  # ── Python runner ──────────────────────────────────────────────────────────

  header "Python Runner"

  if [[ -n "$WORKER_POD" ]]; then
    python_version=$(kubectl exec "$WORKER_POD" -n "$NAMESPACE" -c "$runner_container" \
      -- python3 --version 2>/dev/null || \
      kubectl exec "$WORKER_POD" -n "$NAMESPACE" -c "$runner_container" \
      -- python --version 2>/dev/null || echo "")

    if [[ -n "$python_version" ]]; then
      pass "Python binary present in runner sidecar: $python_version"
    else
      fail "Python binary not found in runner sidecar"
      info "Verify the runner image includes Python support"
    fi

    # Check runner sidecar logs for broker connection
    runner_logs=$(kubectl logs "$WORKER_POD" -n "$NAMESPACE" -c "$runner_container" \
      --tail=50 2>/dev/null || true)

    if echo "$runner_logs" | grep -qiE "connected|ready|broker|listening"; then
      connected_line=$(echo "$runner_logs" | grep -iE "connected|ready|broker|listening" | tail -1)
      pass "Runner sidecar connected to broker"
      info "$connected_line"
    else
      warn "No broker connection confirmation found in runner logs (last 50 lines)"
      info "This may be normal if the runner starts on-demand. Check manually:"
      info "kubectl logs $WORKER_POD -n $NAMESPACE -c $runner_container"
    fi
  else
    skip "Python runner exec checks (no running pod found)"
  fi

else
  warn "Task runner sidecar not detected, task runners may be disabled"
  info "Set n8n_task_runners_enabled = true in terraform.tfvars and re-apply"

  header "Python Runner"
  skip "Python runner checks (task runner sidecar not present)"
fi

fi  # end single-instance checks

# ══════════════════════════════════════════════════════════════════════════════
# MULTI-MAIN CHECKS
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$DEPLOY_MODE" == "multi" ]]; then

# ── Pod health (multi) ────────────────────────────────────────────────────────

header "Pod Health"

check_deployment() {
  local name="$1"
  local min_replicas="$2"
  local label="$3"

  if ! kubectl get deployment "$name" -n "$NAMESPACE" &>/dev/null; then
    fail "Deployment '$name' not found"
    return
  fi

  local ready
  ready=$(kubectl get deployment "$name" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready="${ready:-0}"

  local desired
  desired=$(kubectl get deployment "$name" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "$ready" -ge "$min_replicas" && "$ready" -eq "$desired" ]]; then
    pass "$label: $ready/$desired pods ready"
  elif [[ "$ready" -gt 0 ]]; then
    warn "$label: only $ready/$desired pods ready (minimum $min_replicas)"
  else
    fail "$label: 0/$desired pods ready"
  fi

  local bad_pods
  bad_pods=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=$name" \
    --no-headers 2>/dev/null \
    | awk '{print $1, $3}' \
    | grep -v "Running\|Completed" || true)
  if [[ -n "$bad_pods" ]]; then
    warn "Unhealthy pods detected under $name:"
    while IFS= read -r line; do info "$line"; done <<< "$bad_pods"
  fi
}

check_deployment "n8n-main"              "$MAIN_MIN"    "Main pods"
# A paused worker ScaledObject (n8n_worker_keda_pause = true) legitimately
# holds the Deployment at any count, including 0, so the floor does not apply.
worker_paused=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}' 2>/dev/null || true)
if [[ "$worker_paused" == "true" ]]; then
  worker_held=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}' 2>/dev/null || true)
  skip "Worker pods floor check (ScaledObject paused via n8n_worker_keda_pause; held at ${worker_held:-current count})"
else
  check_deployment "n8n-worker"            "$WORKER_MIN"  "Worker pods"
fi
check_deployment "n8n-webhook-processor" "$WEBHOOK_MIN" "Webhook processor pods"

# ── Task runner sidecars (multi: workers only) ────────────────────────────────

header "Task Runner Sidecars"

# In queue mode, Code nodes execute on worker pods, the task runner sidecar
# belongs on workers, not on main or webhook-processor pods.
worker_containers=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

if echo "$worker_containers" | grep -qiE "runner"; then
  runner_container=$(echo "$worker_containers" | tr ' ' '\n' | grep -iE "runner" | head -1)
  pass "Task runner sidecar present on n8n-worker pods: $runner_container"

  # Confirm sidecar is connected to broker in a running worker pod
  worker_pod=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=worker" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$worker_pod" ]]; then
    runner_logs=$(kubectl logs "$worker_pod" -n "$NAMESPACE" -c "$runner_container" \
      --tail=50 2>/dev/null || true)
    if echo "$runner_logs" | grep -qiE "connected|ready|broker|listening"; then
      connected_line=$(echo "$runner_logs" | grep -iE "connected|ready|broker|listening" | tail -1)
      pass "Worker runner sidecar connected to broker"
      info "$connected_line"
    else
      warn "No broker connection confirmation in worker runner logs (last 50 lines)"
      info "kubectl logs $worker_pod -n $NAMESPACE -c $runner_container"
    fi
  fi
else
  warn "Task runner sidecar not found on n8n-worker, task runners may be disabled"
  info "Set n8n_task_runners_enabled = true in terraform.tfvars and re-apply"
fi

# ── Multi-main leader election ────────────────────────────────────────────────

header "Multi-Main Leader Election"

# n8n uses Redis-based leader election. Verify the feature flag is enabled
# on main pods and that at least one pod reports leadership activity.
main_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=main" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$main_pod" ]]; then
  multi_main=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_MULTI_MAIN_SETUP_ENABLED 2>/dev/null || echo "")
  if [[ "$multi_main" == "true" ]]; then
    pass "N8N_MULTI_MAIN_SETUP_ENABLED=true on main pods, Redis leader election active"
  else
    warn "N8N_MULTI_MAIN_SETUP_ENABLED is not 'true' (got: '${multi_main:-<unset>}')"
    info "Expected when main replica count > 1"
  fi

  leader_log=$(kubectl logs "$main_pod" -n "$NAMESPACE" -c n8n-main --tail=100 2>/dev/null \
    | grep -iE "leader|leadership" | tail -3 || true)
  if [[ -n "$leader_log" ]]; then
    pass "Leader election activity found in logs"
    while IFS= read -r line; do info "$line"; done <<< "$leader_log"
  else
    info "No leadership log lines yet, normal if recently started"
  fi
else
  warn "No running main pod found to check leader election"
fi

# ── Autoscaler configuration ──────────────────────────────────────────────────

header "Autoscaler Configuration"

check_hpa() {
  local name="$1"
  local label="$2"

  if ! kubectl get hpa "$name" -n "$NAMESPACE" &>/dev/null; then
    warn "HPA '$name' not found, HPAs are configured by Terraform, not manual deployment"
    return
  fi

  local min max current targets
  min=$(kubectl get hpa "$name" -n "$NAMESPACE" -o jsonpath='{.spec.minReplicas}')
  max=$(kubectl get hpa "$name" -n "$NAMESPACE" -o jsonpath='{.spec.maxReplicas}')
  current=$(kubectl get hpa "$name" -n "$NAMESPACE" -o jsonpath='{.status.currentReplicas}')
  targets=$(kubectl get hpa "$name" -n "$NAMESPACE" \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "unknown")

  pass "$label HPA: min=$min max=$max current=$current CPU=$targets%"

  if [[ "$current" -eq "$max" ]]; then
    warn "$label is at max replicas ($max), may indicate sustained high load"
  fi
}

check_hpa "n8n-main"              "Main"
check_hpa "n8n-webhook-processor" "Webhook processor"

# Workers: prefer KEDA ScaledObject (queue-depth), fall back to CPU-based HPA
if kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  min=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null || echo "?")
  max=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null || echo "?")
  ready=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  pass "Worker KEDA ScaledObject: min=$min max=$max ready=$ready (queue-depth autoscaling)"
elif kubectl get hpa n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  check_hpa "n8n-worker" "Worker"
else
  warn "No autoscaler found for n8n-worker, expected KEDA ScaledObject or CPU-based HPA"
fi

# ── Queue mode: Redis connectivity ────────────────────────────────────────────

header "Queue Mode, Redis Connectivity"

worker_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=worker" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$worker_pod" ]]; then
  fail "No running worker pod found to probe Redis connectivity"
else
  info "Using worker pod: $worker_pod"

  redis_host=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv QUEUE_BULL_REDIS_HOST 2>/dev/null || true)

  if [[ -n "$redis_host" ]]; then
    pass "Redis host visible in worker environment: $redis_host"
  else
    warn "Could not read Redis host from worker environment"
    info "Manually verify: kubectl exec -n $NAMESPACE $worker_pod -c n8n-worker -- printenv | grep -i redis"
  fi

  if kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
      -- sh -c 'kill -0 1' &>/dev/null; then
    queue_connected=$(kubectl logs "$worker_pod" -n "$NAMESPACE" -c n8n-worker --tail=100 2>/dev/null \
      | grep -iE "queue|bull|redis|worker" | tail -3 || true)
    if [[ -n "$queue_connected" ]]; then
      pass "Worker logs show queue activity"
      while IFS= read -r line; do info "$line"; done <<< "$queue_connected"
    else
      warn "No queue-related log lines found in last 100 worker log lines"
    fi
  fi
fi

fi  # end multi-main checks

# ══════════════════════════════════════════════════════════════════════════════
# COMMON CHECKS (Storage, HTTP, API, Workflow execution)
# ══════════════════════════════════════════════════════════════════════════════

# ── Cluster storage: default StorageClass + its CSI driver ────────────────────
# Would have caught issue #22: a cluster with no CSI driver and no default
# StorageClass leaves every unqualified PVC Pending forever.
#
# Cloud-aware: the module runs on EKS (gp3 / ebs.csi.aws.com) and GKE
# (standard-rwo / pd.csi.storage.gke.io). Rather than assert one cloud's names,
# we require a default StorageClass backed by a recognized managed CSI
# provisioner whose driver pods are actually Running.

header "Cluster Storage"

default_sc=$(kubectl get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
  2>/dev/null || echo "")

if [[ -z "$default_sc" ]]; then
  fail "No default StorageClass, PVCs without storageClassName will stay Pending"
else
  default_sc_provisioner=$(kubectl get storageclass "$default_sc" \
    -o jsonpath='{.provisioner}' 2>/dev/null || echo "")

  # Map the default SC's provisioner to a cloud label + the kube-system label
  # selector its CSI driver pods carry.
  csi_label=""
  csi_selector=""
  case "$default_sc_provisioner" in
    ebs.csi.aws.com)
      csi_label="AWS EBS CSI"
      csi_selector="app.kubernetes.io/name=aws-ebs-csi-driver" ;;
    pd.csi.storage.gke.io)
      csi_label="GKE PD CSI"
      csi_selector="k8s-app=gcp-compute-persistent-disk-csi-driver" ;;
    disk.csi.azure.com)
      csi_label="Azure Disk CSI"
      csi_selector="app=csi-azuredisk-node" ;;
  esac

  if [[ -n "$csi_label" ]]; then
    pass "Default StorageClass '$default_sc' uses a managed CSI provisioner ($default_sc_provisioner, $csi_label)"
  elif [[ -n "$default_sc_provisioner" ]]; then
    warn "Default StorageClass '$default_sc' provisioner is '$default_sc_provisioner' (unrecognized; ensure it is a working dynamic provisioner)"
  else
    fail "Default StorageClass '$default_sc' has no provisioner"
  fi

  # grep -c (not -q): -q exits at the first match, kubectl takes a SIGPIPE on
  # the remaining lines, and pipefail turns that into a false failure.
  if [[ -n "$csi_selector" ]]; then
    running_csi_pods=$(kubectl get pods -n kube-system -l "$csi_selector" \
      --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "${running_csi_pods:-0}" -gt 0 ]]; then
      pass "$csi_label driver pods are running in kube-system ($running_csi_pods pods)"
    else
      fail "No running $csi_label driver pods in kube-system"
    fi
  else
    skip "CSI driver pod check (unrecognized provisioner '${default_sc_provisioner:-none}')"
  fi
fi

# ── HTTP health check ─────────────────────────────────────────────────────────

header "HTTP Health Check"

if [[ -z "$N8N_URL" ]]; then
  skip "HTTP health check (N8N_URL not set)"
else
  healthz_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    --max-time 10 "${N8N_URL%/}/healthz" || echo "000")

  if [[ "$healthz_status" == "200" ]]; then
    pass "/healthz returned HTTP $healthz_status"
  elif [[ "$healthz_status" == "000" ]]; then
    fail "/healthz, connection failed (timeout or DNS error)"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      info "On macOS, a recent destroy + re-apply against the same FQDN often"
      info "leaves mDNSResponder serving the destroy-phase NXDOMAIN for 5-15 min."
      info "Fix: sudo killall -HUP mDNSResponder"
      info "Details: docs/troubleshooting.md → 'Smoke test reports HTTP 000'"
    fi
  else
    fail "/healthz returned HTTP $healthz_status (expected 200)"
  fi

  # Verify HTTP → HTTPS redirect
  http_url="${N8N_URL/https:/http:}"
  if [[ "$http_url" != "$N8N_URL" ]]; then
    redirect_status=$(curl -sk -o /dev/null -w "%{http_code}" \
      --max-time 10 "$http_url" || echo "000")
    if [[ "$redirect_status" =~ ^30[1-8]$ ]]; then
      pass "HTTP → HTTPS redirect: $redirect_status"
    elif [[ "$redirect_status" == "000" ]]; then
      warn "HTTP redirect check, connection failed"
    else
      warn "HTTP → HTTPS redirect returned $redirect_status (expected 301/302/307/308)"
    fi
  fi
fi

# ── API connectivity ──────────────────────────────────────────────────────────

header "API Connectivity"

if [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "API connectivity test (requires N8N_URL and N8N_API_KEY)"
else
  api_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "${N8N_URL%/}/api/v1/workflows?limit=1" || echo "000")

  if [[ "$api_status" == "200" ]]; then
    pass "API /api/v1/workflows responded HTTP $api_status"
  elif [[ "$api_status" == "401" ]]; then
    fail "API returned 401 Unauthorized, check your N8N_API_KEY"
  elif [[ "$api_status" == "000" ]]; then
    fail "API, connection failed (timeout or DNS error)"
  else
    fail "API /api/v1/workflows returned HTTP $api_status"
  fi
fi

# ── Workflow execution ────────────────────────────────────────────────────────
#
# Single mode: Webhook → JS Code → Python Code
#   Exercises both task runner language runtimes end-to-end.
#
# Multi mode: Webhook → Set
#   Lightweight, verifies queue routing; task runner is covered by the
#   sidecar check above.

if [[ "$DEPLOY_MODE" == "single" ]]; then
  header "Workflow Execution (JS + Python runners)"
else
  header "Workflow Execution via Queue"
fi

if [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "Workflow execution test (requires N8N_URL and N8N_API_KEY)"
else
  webhook_path="smoke-test-$$"

  if [[ "$DEPLOY_MODE" == "single" ]]; then
    # Single: Webhook → JS Code → Python Code (exercises both runners)
    workflow_payload="{
      \"name\": \"__smoke-test__\",
      \"nodes\": [
        {
          \"id\": \"a1b2c3d4-0001-0001-0001-000000000001\",
          \"name\": \"Webhook\",
          \"type\": \"n8n-nodes-base.webhook\",
          \"typeVersion\": 1,
          \"position\": [250, 300],
          \"webhookId\": \"${webhook_path}\",
          \"parameters\": {
            \"httpMethod\": \"POST\",
            \"path\": \"${webhook_path}\",
            \"responseMode\": \"onReceived\"
          }
        },
        {
          \"id\": \"a1b2c3d4-0002-0002-0002-000000000002\",
          \"name\": \"JS Code\",
          \"type\": \"n8n-nodes-base.code\",
          \"typeVersion\": 2,
          \"position\": [450, 300],
          \"parameters\": {
            \"jsCode\": \"return [{ json: { js_runner: 'passed' } }];\"
          }
        },
        {
          \"id\": \"a1b2c3d4-0003-0003-0003-000000000003\",
          \"name\": \"Python Code\",
          \"type\": \"n8n-nodes-base.code\",
          \"typeVersion\": 2,
          \"position\": [650, 300],
          \"parameters\": {
            \"language\": \"python\",
            \"pythonCode\": \"return [{'json': {'python_runner': 'passed'}}]\"
          }
        }
      ],
      \"connections\": {
        \"Webhook\": {
          \"main\": [[{ \"node\": \"JS Code\", \"type\": \"main\", \"index\": 0 }]]
        },
        \"JS Code\": {
          \"main\": [[{ \"node\": \"Python Code\", \"type\": \"main\", \"index\": 0 }]]
        }
      },
      \"settings\": {}
    }"
    exec_success_msg="Execution completed successfully, JS and Python runners both processed"
  else
    # Multi: Webhook → Set (lightweight queue-mode test)
    workflow_payload="{
      \"name\": \"__smoke-test__\",
      \"nodes\": [
        {
          \"id\": \"a1b2c3d4-0001-0001-0001-000000000001\",
          \"name\": \"Webhook\",
          \"type\": \"n8n-nodes-base.webhook\",
          \"typeVersion\": 1,
          \"position\": [250, 300],
          \"webhookId\": \"${webhook_path}\",
          \"parameters\": {
            \"httpMethod\": \"POST\",
            \"path\": \"${webhook_path}\",
            \"responseMode\": \"onReceived\"
          }
        },
        {
          \"id\": \"a1b2c3d4-0002-0002-0002-000000000002\",
          \"name\": \"Set\",
          \"type\": \"n8n-nodes-base.set\",
          \"typeVersion\": 3.4,
          \"position\": [450, 300],
          \"parameters\": {
            \"assignments\": {
              \"assignments\": [
                { \"id\": \"1\", \"name\": \"smoke_test\", \"value\": \"passed\", \"type\": \"string\" }
              ]
            }
          }
        }
      ],
      \"connections\": {
        \"Webhook\": {
          \"main\": [[{ \"node\": \"Set\", \"type\": \"main\", \"index\": 0 }]]
        }
      },
      \"settings\": {}
    }"
    exec_success_msg="Execution completed successfully, queue mode is working"
  fi

  # Create workflow
  create_response=$(curl -sk -w "\n%{http_code}" \
    --max-time 15 \
    -X POST \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$workflow_payload" \
    "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

  create_status=$(echo "$create_response" | tail -1)
  create_body=$(echo "$create_response" | sed '$d')

  if [[ "$create_status" != "200" ]]; then
    fail "Failed to create test workflow (HTTP $create_status)"
    info "Response: $create_body"
    info "Skipping execution test"
  else
    workflow_id=$(echo "$create_body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
    pass "Test workflow created (id: $workflow_id)"
    if [[ "$DEPLOY_MODE" == "single" ]]; then
      info "Webhook → JS Code node → Python Code node (exercises both runners)"
    fi

    # Activate so the webhook listener starts
    activate_status=$(curl -sk -o /dev/null -w "%{http_code}" \
      --max-time 10 \
      -X POST \
      -d '{}' \
      -H "Content-Type: application/json" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}/activate" 2>/dev/null || echo "000")

    if [[ "$activate_status" != "200" ]]; then
      fail "Failed to activate test workflow (HTTP $activate_status)"
    else
      pass "Test workflow activated"

      if [[ "$DEPLOY_MODE" == "multi" ]]; then
        info "Waiting 5s for webhook-processor to register the new webhook..."
        sleep 5
        info "Triggering execution via webhook, will be queued to a worker"

        trigger_status=$(curl -sk -o /dev/null -w "%{http_code}" \
          --max-time 15 \
          -X POST \
          -H "Content-Type: application/json" \
          -d '{"smoke_test": true}' \
          "${N8N_URL%/}/webhook/${webhook_path}" 2>/dev/null || echo "000")
        trigger_body=""
      else
        info "Triggering execution via webhook → Code node (exercises task runner)"

        # Poll until the webhook is registered (up to 15s)
        trigger_status="000"
        trigger_body=""
        for _w in $(seq 1 5); do
          sleep 3
          trigger_response=$(curl -sk -w "\n%{http_code}" \
            --max-time 15 \
            -X POST \
            -H "Content-Type: application/json" \
            -d '{"smoke_test": true}' \
            "${N8N_URL%/}/webhook/${webhook_path}" 2>/dev/null || echo -e "\n000")
          trigger_status=$(echo "$trigger_response" | tail -1)
          trigger_body=$(echo "$trigger_response" | sed '$d')
          [[ "$trigger_status" =~ ^2 ]] && break
          [[ "$trigger_status" == "404" ]] && continue
          break
        done
      fi

      if [[ "$trigger_status" =~ ^2 ]]; then
        pass "Webhook triggered (HTTP $trigger_status)"

        info "Waiting for execution to complete..."
        exec_state="unknown"
        for i in $(seq 1 15); do
          sleep 2
          exec_state=$(curl -sk \
            --max-time 10 \
            -H "X-N8N-API-KEY: $N8N_API_KEY" \
            "${N8N_URL%/}/api/v1/executions?workflowId=${workflow_id}&limit=1" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); execs=d.get('data',[]); print(execs[0]['status'] if execs else 'pending')" 2>/dev/null \
            || echo "unknown")

          if [[ "$exec_state" == "success" ]]; then
            pass "$exec_success_msg"
            break
          elif [[ "$exec_state" == "error" || "$exec_state" == "crashed" ]]; then
            fail "Execution ended with status: $exec_state"
            if [[ "$DEPLOY_MODE" == "single" && -n "${N8N_POD:-}" ]]; then
              info "Check logs: kubectl logs $N8N_POD -n $NAMESPACE -c n8n --tail=50"
            fi
            break
          elif [[ "$i" -eq 15 ]]; then
            warn "Execution still in state '$exec_state' after 30s"
            if [[ "$DEPLOY_MODE" == "multi" ]]; then
              info "May be slow to process, check: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=worker --tail=50"
            fi
          fi
        done
      else
        fail "Webhook trigger failed (HTTP $trigger_status)"
        info "Webhook URL: ${N8N_URL%/}/webhook/${webhook_path}"
        [[ -n "$trigger_body" ]] && info "Response: $trigger_body"
      fi
    fi

    # Cleanup, deactivate then delete
    curl -sk -o /dev/null --max-time 10 -X POST \
      -d '{}' \
      -H "Content-Type: application/json" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}/deactivate" 2>/dev/null || true
    curl -sk -o /dev/null --max-time 10 -X DELETE \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}" 2>/dev/null || true
    info "Test workflow deleted"
  fi
fi

# ── Worker scaling test (multi only, optional) ────────────────────────────────
#
# Creates a temporary CPU-burning workflow, queues LOAD_REQUESTS concurrent
# executions, and verifies that the worker HPA/KEDA scales up.
#
# Why not /healthz? Those requests never touch worker pods, they hit the main
# pods' HTTP listener. Workers only get CPU when executing workflows.

if [[ "$DEPLOY_MODE" == "multi" ]]; then

header "Worker Scaling Test"

if [[ "$LOAD_TEST" != "true" ]]; then
  skip "Load scaling test (set LOAD_TEST=true to enable)"
elif [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "Load scaling test (requires N8N_URL and N8N_API_KEY)"
else
  SCALER_MODE=""
  if kubectl get hpa n8n-worker -n "$NAMESPACE" &>/dev/null; then
    worker_hpa_targets=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
      --no-headers 2>/dev/null | awk '{print $3}' || echo "<unknown>")
    if [[ "$worker_hpa_targets" == *"<unknown>"* ]]; then
      warn "HPA CPU metrics are <unknown>, metrics-server is not installed or not yet ready"
      info "Install metrics-server if not already done, then wait ~2 minutes for metrics to populate."
      info "Verify: kubectl top pods -n $NAMESPACE"
      info "Skipping load test, it cannot demonstrate scaling in this state."
    else
      SCALER_MODE="hpa"
    fi
  elif kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null; then
    info "No HPA found, KEDA ScaledObject detected. Scaling is queue-depth driven (Redis)."
    SCALER_MODE="keda"
  else
    skip "Load scaling test, no HPA or KEDA ScaledObject found for n8n-worker"
  fi

  if [[ -n "$SCALER_MODE" ]]; then
    load_webhook_path="smoke-load-$$"
    load_duration_ms=$((LOAD_JOB_DURATION_SECS * 1000))
    load_js="const end = Date.now() + ${load_duration_ms}; let x = 0; while (Date.now() < end) { for (let i = 0; i < 100000; i++) x += Math.sqrt(i); } return [{json: {done: true, elapsed: Date.now() - (end - ${load_duration_ms})}}];"

    load_workflow_payload=$(cat <<EOF
{
  "name": "__smoke-load-test__",
  "nodes": [
    {
      "id": "a1b2c3d4-0011-0011-0011-000000000011",
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [250, 300],
      "webhookId": "${load_webhook_path}",
      "parameters": {
        "httpMethod": "POST",
        "path": "${load_webhook_path}",
        "responseMode": "onReceived"
      }
    },
    {
      "id": "a1b2c3d4-0012-0012-0012-000000000012",
      "name": "CPU Burn",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [450, 300],
      "parameters": {
        "jsCode": "${load_js}"
      }
    }
  ],
  "connections": {
    "Webhook": {
      "main": [[{"node": "CPU Burn", "type": "main", "index": 0}]]
    }
  },
  "settings": {}
}
EOF
    )

    load_workflow_id=""

    load_create_response=$(curl -sk -w "\n%{http_code}" \
      --max-time 15 \
      -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$load_workflow_payload" \
      "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

    load_create_status=$(echo "$load_create_response" | tail -1)
    load_create_body=$(echo "$load_create_response" | sed '$d')

    if [[ "$load_create_status" != "200" ]]; then
      warn "Could not create load test workflow (HTTP $load_create_status), skipping scaling test"
      info "Response: $load_create_body"
    else
      load_workflow_id=$(echo "$load_create_body" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
      info "Load test workflow created (id: $load_workflow_id, CPU burn: ${LOAD_JOB_DURATION_SECS}s per job)"

      load_activate_status=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        -X POST \
        -d '{}' \
        -H "Content-Type: application/json" \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}/activate" 2>/dev/null || echo "000")

      if [[ "$load_activate_status" != "200" ]]; then
        warn "Could not activate load test workflow (HTTP $load_activate_status), skipping scaling test"
      else
        if [[ "$SCALER_MODE" == "hpa" ]]; then
          worker_before=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
            -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
        else
          worker_before=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
          worker_before="${worker_before:-0}"
        fi
        info "Baseline, worker: $worker_before replica(s)"

        # Clamp seed batch to total request count
        load_seed=$LOAD_SEED_JOBS
        [[ $load_seed -gt $LOAD_REQUESTS ]] && load_seed=$LOAD_REQUESTS
        load_remaining=$((LOAD_REQUESTS - load_seed))

        # Phase 1: queue seed jobs to signal the autoscaler
        if [[ "$SCALER_MODE" == "keda" ]]; then
          info "Phase 1: queuing $load_seed seed jobs to build queue depth (KEDA trigger)..."
        else
          info "Phase 1: queuing $load_seed seed jobs, each burns ~${LOAD_JOB_DURATION_SECS}s CPU (HPA trigger)..."
        fi

        for i in $(seq 1 "$load_seed"); do
          curl -sk -o /dev/null --max-time 10 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"job\": $i}" \
            "${N8N_URL%/}/webhook/${load_webhook_path}" &
          if (( i % LOAD_CONCURRENCY == 0 )); then wait || true; fi
        done
        wait || true
        info "$load_seed seed jobs queued. Polling for scale-up (max ${SCALE_WAIT_SECS}s)..."

        # Poll for scale-up
        worker_scaled=false
        worker_after="$worker_before"
        elapsed=0
        poll_interval=15
        while [[ $elapsed -lt $SCALE_WAIT_SECS ]]; do
          sleep $poll_interval
          elapsed=$((elapsed + poll_interval))
          if [[ "$SCALER_MODE" == "hpa" ]]; then
            worker_now=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
              -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
          else
            worker_now=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
              -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            worker_now="${worker_now:-0}"
          fi
          if [[ "$worker_now" -gt "$worker_before" ]]; then
            worker_scaled=true
            worker_after="$worker_now"
            break
          fi
          info "  ${elapsed}s / ${SCALE_WAIT_SECS}s, worker replicas: ${worker_now} (waiting for > $worker_before)"
        done

        if [[ "$worker_scaled" == "true" ]]; then
          pass "Worker pods scaled: $worker_before → $worker_after (detected after ${elapsed}s)"

          # Phase 2: queue remaining jobs so the new workers are visibly utilized
          if [[ $load_remaining -gt 0 ]]; then
            info "Phase 2: queuing $load_remaining remaining jobs across $worker_after worker(s)..."
            info "Watch new workers pick up jobs: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=worker -w"
            for i in $(seq $((load_seed + 1)) "$LOAD_REQUESTS"); do
              curl -sk -o /dev/null --max-time 10 \
                -X POST \
                -H "Content-Type: application/json" \
                -d "{\"job\": $i}" \
                "${N8N_URL%/}/webhook/${load_webhook_path}" &
              if (( (i - load_seed) % LOAD_CONCURRENCY == 0 )); then wait || true; fi
            done
            wait || true
            info "All $LOAD_REQUESTS jobs queued total, $load_seed seed + $load_remaining follow-on"
          fi
        else
          warn "Worker pods did not scale ($worker_before → $worker_after) within ${SCALE_WAIT_SECS}s"
          if [[ "$SCALER_MODE" == "keda" ]]; then
            info "Diagnose: kubectl describe scaledobject n8n-worker -n $NAMESPACE"
            info "Check queue depth: kubectl exec -n $NAMESPACE \$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=redis -o name | head -1) -- redis-cli llen bull:jobs:wait"
          else
            info "Diagnose: kubectl describe hpa n8n-worker -n $NAMESPACE"
          fi
          info "Try: LOAD_REQUESTS=100 LOAD_JOB_DURATION_SECS=10 LOAD_TEST=true ./smoke-test.sh"
        fi

        if [[ "$SCALER_MODE" == "hpa" ]]; then
          info "Current HPA state:"
          kubectl get hpa -n "$NAMESPACE" 2>/dev/null | while IFS= read -r line; do info "$line"; done
        else
          info "Current KEDA ScaledObject state:"
          kubectl get scaledobject -n "$NAMESPACE" 2>/dev/null | while IFS= read -r line; do info "$line"; done
        fi
      fi

      if [[ -n "$load_workflow_id" ]]; then
        curl -sk -o /dev/null --max-time 10 -X POST \
          -d '{}' \
          -H "Content-Type: application/json" \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}/deactivate" 2>/dev/null || true
        curl -sk -o /dev/null --max-time 10 -X DELETE \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}" 2>/dev/null || true
        info "Load test workflow deleted"
      fi
    fi
  fi
fi

fi  # end multi-only load test

# ══════════════════════════════════════════════════════════════════════════════
# CUSTOMER-MANAGED INFRASTRUCTURE CHECKS
# ══════════════════════════════════════════════════════════════════════════════
#
# These checks verify behaviors that mocked `terraform test` providers cannot
# prove, and apply the same way whether the underlying layer is
# module-managed or customer-managed (see
# docs/customer-managed-infrastructure.md for the ownership contract). Each
# is best-effort and skips cleanly when its prerequisite value or tooling is
# unavailable, rather than failing the whole run.

# ── Redis TLS and AUTH ────────────────────────────────────────────────────────

header "Redis TLS and AUTH"

worker_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=worker" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$worker_pod" ]]; then
  skip "Redis TLS/AUTH check (no running worker pod found)"
else
  redis_tls_env=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv QUEUE_BULL_REDIS_TLS 2>/dev/null || true)
  redis_pass_env=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- sh -c 'test -n "$QUEUE_BULL_REDIS_PASSWORD" && echo set || echo unset' 2>/dev/null || true)

  if [[ "$REDIS_TLS_ENABLED" == "true" ]]; then
    if [[ "$redis_tls_env" == "true" ]]; then
      pass "Worker connects to Redis over TLS (QUEUE_BULL_REDIS_TLS=true), matching the effective redis_tls_enabled output"
    else
      fail "redis_tls_enabled output is true but QUEUE_BULL_REDIS_TLS is '${redis_tls_env:-<unset>}' on the worker pod"
    fi
  else
    info "Effective redis_tls_enabled is not true, skipping the TLS assertion (QUEUE_BULL_REDIS_TLS=${redis_tls_env:-<unset>})"
  fi

  if [[ "$redis_pass_env" == "set" ]]; then
    pass "Worker has a Redis AUTH/password configured (QUEUE_BULL_REDIS_PASSWORD is set)"
  else
    info "No Redis password configured on the worker pod (QUEUE_BULL_REDIS_PASSWORD unset); expected when redis_auth_enabled = false and no external password source is set"
  fi
fi

# ── GCS binary/execution-data access ──────────────────────────────────────────

header "GCS Object Storage Access"

if [[ -z "$GCS_BUCKET_NAME" ]]; then
  skip "GCS access check (gcs_bucket_name output not available)"
elif [[ -z "$worker_pod" ]]; then
  skip "GCS access check (no running worker pod found)"
else
  s3_host=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv N8N_EXTERNAL_STORAGE_S3_HOST 2>/dev/null || true)
  if [[ -n "$s3_host" ]]; then
    pass "S3-compatible GCS endpoint configured on worker: $s3_host (bucket: $GCS_BUCKET_NAME)"
  else
    warn "Could not read N8N_EXTERNAL_STORAGE_S3_HOST from the worker environment"
    info "Manually verify: kubectl exec -n $NAMESPACE $worker_pod -c n8n-worker -- printenv | grep -i s3"
  fi

  if command -v gcloud &>/dev/null; then
    if gcloud storage objects list "gs://${GCS_BUCKET_NAME}" --limit=1 &>/dev/null; then
      pass "Bucket '$GCS_BUCKET_NAME' is reachable and listable with the active gcloud identity"
    else
      info "Could not list gs://${GCS_BUCKET_NAME} with the active gcloud identity (expected if your identity differs from the n8n Workload Identity service account; this does not indicate n8n itself lacks access)"
    fi
  else
    skip "Direct bucket listing (gcloud not installed)"
  fi
fi

# ── Referenced Secrets exist ───────────────────────────────────────────────────
# Best-effort: only checks the well-known Secret names this module wires by
# convention. A custom name passed via *_secret_ref still needs manual
# verification; see docs/troubleshooting.md → 'Referenced Secret errors'.

header "Referenced Secrets"

for secret_name in n8n-secret n8n-db-secret n8n-redis-secret n8n-s3-secret; do
  if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
    pass "Secret '$secret_name' exists in namespace '$NAMESPACE'"
  else
    info "Secret '$secret_name' not found (expected if that credential family uses an existing-Secret reference under a different name, or a direct value)"
  fi
done

# ── KEDA reads (ScaledObject and TriggerAuthentication) ───────────────────────

header "KEDA Reads"

if kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  ready=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  active=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "?")
  if [[ "$ready" == "True" ]]; then
    pass "KEDA ScaledObject 'n8n-worker' is Ready (Active=$active), reading the Redis queue depth trigger"
  else
    fail "KEDA ScaledObject 'n8n-worker' is not Ready (Ready=$ready, Active=$active)"
    info "Diagnose: kubectl describe scaledobject n8n-worker -n $NAMESPACE"
  fi

  if kubectl get triggerauthentication -n "$NAMESPACE" &>/dev/null 2>&1; then
    ta_count=$(kubectl get triggerauthentication -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ta_count" -gt 0 ]]; then
      pass "TriggerAuthentication present ($ta_count), a Redis password source is configured"
    else
      info "No TriggerAuthentication found, expected when no Redis password source is configured"
    fi
  fi
else
  skip "KEDA reads check (no n8n-worker ScaledObject found, worker autoscaling may use a fixed replica count or a customer-owned scaler)"
fi

# ── Ingress routes ─────────────────────────────────────────────────────────────

header "Ingress Routes"

if [[ -z "$N8N_URL" ]]; then
  skip "Ingress route checks (N8N_URL not set)"
else
  # Main route: anything not in the webhook prefix list, verified via the root path.
  main_status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "${N8N_URL%/}/" || echo "000")
  if [[ "$main_status" =~ ^(200|301|302)$ ]]; then
    pass "Main route '/' responded HTTP $main_status"
  else
    warn "Main route '/' responded HTTP $main_status (expected 200/301/302)"
  fi

  if [[ -n "$N8N_WEBHOOK_ROUTE_PREFIXES_JSON" ]] && command -v python3 &>/dev/null; then
    webhook_prefixes=$(echo "$N8N_WEBHOOK_ROUTE_PREFIXES_JSON" \
      | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))" 2>/dev/null || true)
    if [[ -n "$webhook_prefixes" ]]; then
      while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue
        route_status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "${N8N_URL%/}${prefix}" || echo "000")
        # A bare prefix with no matching webhook/form path 404s at the n8n
        # application layer, which still proves the ingress routed the
        # request to the webhook service; only a 000 (unreachable) or 5xx
        # (misrouted/misconfigured backend) indicates an ingress problem.
        if [[ "$route_status" == "000" ]]; then
          fail "Webhook route '$prefix' unreachable (connection failed)"
        elif [[ "$route_status" =~ ^5 ]]; then
          fail "Webhook route '$prefix' returned HTTP $route_status (backend error, check it routes to $N8N_WEBHOOK_SERVICE, not $N8N_MAIN_SERVICE)"
        else
          pass "Webhook route '$prefix' reachable (HTTP $route_status)"
        fi
      done <<< "$webhook_prefixes"
    fi
  else
    skip "Webhook route prefix checks (n8n_webhook_route_prefixes output or python3 not available)"
  fi
fi

# ── New contracts (add-google-parity-through-aws-0-4-0) ───────────────────────
#
# Read-only inspection of the runtime contracts this change added: main
# topology, Redis namespace isolation, the opt-in Redis exporter,
# reference-only Secret/ConfigMap mounts, the V8 heap ceiling, pod DNS, and
# additional ingress hostnames. None of these checks drain queues, restart
# deployments, rotate credentials, or apply infrastructure; they only read
# already-running objects. Each skips cleanly when its prerequisite output,
# pod, or tooling is unavailable.

header "Main Topology"

main_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=main" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if ! kubectl get deployment n8n-main -n "$NAMESPACE" &>/dev/null; then
  skip "Main topology check (n8n-main deployment not found)"
else
  main_replicas=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  main_strategy=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
    -o jsonpath='{.spec.strategy.type}' 2>/dev/null || echo "")
  main_pdb_min=$(kubectl get pdb -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk 'tolower($1) ~ /main/ {print $1, $3; exit}')

  if [[ "$main_replicas" -eq 1 && "$main_strategy" == "Recreate" ]]; then
    pass "Single-main topology detected: n8n-main replicas=1, strategy=Recreate"
    if [[ -n "$main_pdb_min" ]]; then
      main_pdb_min_value=$(echo "$main_pdb_min" | awk '{print $2}')
      if [[ "$main_pdb_min_value" == "0" ]]; then
        pass "Main PodDisruptionBudget minAvailable=0 (expected for single-main)"
      else
        warn "Main PodDisruptionBudget minAvailable='$main_pdb_min_value' (expected 0 for single-main)"
      fi
    else
      info "Could not identify a main PodDisruptionBudget by name, inspect manually: kubectl get pdb -n $NAMESPACE"
    fi
    info "Editor, REST API, and scheduled triggers are interrupted during any main rollout or maintenance in this topology."
  elif [[ "$main_replicas" -gt 1 ]]; then
    pass "Multi-main topology detected: n8n-main replicas=$main_replicas, strategy=${main_strategy:-<default>}"
    if [[ -n "$main_pod" ]]; then
      multi_main=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
        -- printenv N8N_MULTI_MAIN_SETUP_ENABLED 2>/dev/null || echo "")
      if [[ "$multi_main" == "true" ]]; then
        pass "N8N_MULTI_MAIN_SETUP_ENABLED=true on main pods"
      else
        warn "N8N_MULTI_MAIN_SETUP_ENABLED is not 'true' on a multi-replica main deployment (got: '${multi_main:-<unset>}')"
      fi
    fi
  else
    info "n8n-main replicas=$main_replicas, strategy=${main_strategy:-<unknown>} (unable to classify topology)"
  fi
fi

header "Redis Namespace Isolation"

worker_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=worker" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$worker_pod" ]]; then
  skip "Redis command-channel/Bull prefix check (no running worker pod found)"
else
  bull_prefix=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- sh -c 'printenv QUEUE_BULL_PREFIX 2>/dev/null || true')
  command_prefix=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- sh -c 'printenv N8N_REDIS_KEY_PREFIX 2>/dev/null || true')

  if [[ -z "$bull_prefix" && -z "$command_prefix" ]]; then
    info "No custom redis_key_prefix configured, n8n uses its own defaults (command prefix 'n8n', Bull prefix 'bull')"
  elif [[ "$bull_prefix" == "$command_prefix" ]]; then
    pass "Bull queue prefix and command-channel prefix match: '$bull_prefix'"
  else
    fail "Bull queue prefix ('${bull_prefix:-<unset>}') and command-channel prefix ('${command_prefix:-<unset>}') differ, expected redis_key_prefix to set both"
  fi
fi

header "Redis Exporter"

if [[ -z "$REDIS_EXPORTER_SERVICE" ]]; then
  skip "Redis exporter check (redis_exporter_service_name output is null, redis_exporter_enabled = false)"
else
  if kubectl get service "$REDIS_EXPORTER_SERVICE" -n "$NAMESPACE" &>/dev/null; then
    pass "Redis exporter Service '$REDIS_EXPORTER_SERVICE' exists"
  else
    fail "Redis exporter Service '$REDIS_EXPORTER_SERVICE' not found, but redis_exporter_service_name output is set"
  fi

  if kubectl get deployment redis-exporter -n "$NAMESPACE" &>/dev/null; then
    exporter_ready=$(kubectl get deployment redis-exporter -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    exporter_ready="${exporter_ready:-0}"
    if [[ "$exporter_ready" -ge 1 ]]; then
      pass "Redis exporter deployment ready ($exporter_ready/1)"
    else
      fail "Redis exporter deployment not ready (0/1)"
    fi
  else
    fail "Redis exporter Deployment 'redis-exporter' not found"
  fi
  info "Metrics endpoint and TLS trust are not probed automatically; verify manually with:"
  info "  kubectl port-forward -n $NAMESPACE svc/$REDIS_EXPORTER_SERVICE 9121:9121 && curl -s localhost:9121/metrics"
fi

header "Reference-Only Mounts and Runtime Settings"

if [[ -n "$main_pod" ]]; then
  overwrite_file=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- sh -c 'printenv CREDENTIALS_OVERWRITE_DATA_FILE 2>/dev/null || true')
  if [[ -n "$overwrite_file" ]]; then
    if kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
        -- sh -c "test -r '$overwrite_file'" &>/dev/null; then
      pass "Credentials-overwrite file readable at '$overwrite_file' (content not inspected)"
    else
      fail "CREDENTIALS_OVERWRITE_DATA_FILE='$overwrite_file' set but not readable in n8n-main, check n8n_credentials_overwrite_secret_ref"
    fi
  else
    info "n8n_credentials_overwrite_secret_ref not configured (CREDENTIALS_OVERWRITE_DATA_FILE unset)"
  fi

  # Since chart 1.13.0 the task-runner sidecar (and its launcher-config
  # volume) renders on worker pods only in queue mode.
  runner_cfg_pod=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=worker" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  runner_config_volume=$(kubectl get pod "${runner_cfg_pod:-$main_pod}" -n "$NAMESPACE" \
    -o jsonpath='{.spec.volumes[?(@.name=="task-runner-config")].configMap.name}' 2>/dev/null || true)
  if [[ -n "$runner_config_volume" ]]; then
    pass "Task-runner custom launcher configuration mounted from ConfigMap '$runner_config_volume' (volume 'task-runner-config' on ${runner_cfg_pod:-$main_pod})"
  else
    info "n8n_task_runner_custom_config not configured (no 'task-runner-config' volume on worker pod ${runner_cfg_pod:-<none>})"
  fi

  heap_ceiling=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- sh -c 'printenv NODE_OPTIONS 2>/dev/null || true')
  if [[ -n "$heap_ceiling" ]]; then
    pass "NODE_OPTIONS set on n8n-main: $heap_ceiling"
  else
    info "n8n_node_max_old_space_size_mb not configured (NODE_OPTIONS unset)"
  fi

  dns_search=$(kubectl get pod "$main_pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.dnsConfig}' 2>/dev/null || true)
  if [[ -n "$dns_search" && "$dns_search" != "{}" && "$dns_search" != "map[]" ]]; then
    pass "Pod dnsConfig present on n8n-main: $dns_search"
  else
    info "n8n_dns_config not configured (no custom pod dnsConfig)"
  fi
else
  skip "Reference-only mount and runtime setting checks (no running main pod found)"
fi

if kubectl get secret n8n-license-secret -n "$NAMESPACE" &>/dev/null; then
  pass "Managed license Secret 'n8n-license-secret' exists (n8n_license_key delivered by reference, no literal key in Helm values)"
else
  info "Secret 'n8n-license-secret' not found (expected when n8n_license_key is unset or n8n_license_key_secret_ref is used instead)"
fi

header "Additional Ingress Hostnames"

if [[ -z "$N8N_INGRESS_HOSTS_JSON" ]]; then
  skip "Additional hostname reachability (n8n_ingress_hosts output not available)"
elif ! command -v python3 &>/dev/null; then
  skip "Additional hostname reachability (python3 not available)"
else
  ingress_hosts=$(echo "$N8N_INGRESS_HOSTS_JSON" \
    | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))" 2>/dev/null || true)
  if [[ -z "$ingress_hosts" ]]; then
    skip "Additional hostname reachability (no hostnames in n8n_ingress_hosts)"
  else
    while IFS= read -r host; do
      [[ -z "$host" ]] && continue
      host_status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "https://${host}/healthz" || echo "000")
      if [[ "$host_status" == "200" ]]; then
        pass "Hostname '$host' /healthz returned HTTP 200"
      elif [[ "$host_status" == "000" ]]; then
        warn "Hostname '$host' unreachable (connection failed); verify DNS/certificate coverage for this alias"
      else
        warn "Hostname '$host' /healthz returned HTTP $host_status (expected 200)"
      fi
    done <<< "$ingress_hosts"
  fi
fi

# ── Duplicate customer-managed resource detection ─────────────────────────────
# On a mixed-ownership deployment, the module must never create a second copy
# of a resource you already own (a second namespace, a second KEDA install, a
# second Service backing the same route). This is primarily a `terraform
# plan` concern (see docs/destroy-cleanup.md → 'Customer-managed layers'), but
# a live cluster can also surface it as duplicate objects.

header "Duplicate Customer-Managed Resource Detection"

namespace_count=$(kubectl get namespace "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$namespace_count" -le 1 ]]; then
  pass "Exactly one namespace named '$NAMESPACE' exists"
else
  fail "Found $namespace_count namespaces named '$NAMESPACE' (expected exactly one)"
fi

keda_operator_count=$(kubectl get deployment -A -l app.kubernetes.io/name=keda-operator \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$keda_operator_count" -le 1 ]]; then
  pass "At most one KEDA operator deployment found cluster-wide ($keda_operator_count)"
else
  fail "Found $keda_operator_count KEDA operator deployments cluster-wide (expected at most one; a module-installed KEDA alongside an existing one is a sign install_keda should be false)"
fi

if [[ -n "$N8N_MAIN_SERVICE" ]]; then
  main_svc_count=$(kubectl get service "$N8N_MAIN_SERVICE" -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$main_svc_count" -eq 1 ]]; then
    pass "Exactly one Service named '$N8N_MAIN_SERVICE' exists in '$NAMESPACE'"
  else
    warn "Found $main_svc_count Services named '$N8N_MAIN_SERVICE' in '$NAMESPACE' (expected exactly one)"
  fi
fi

echo ""
echo -e "${BOLD}══════════════════════════════════════${RESET}"
echo -e "${BOLD}  Smoke Test Summary  [mode: $DEPLOY_MODE]${RESET}"
echo -e "${BOLD}══════════════════════════════════════${RESET}"
echo -e "  ${GREEN}Passed:${RESET}  $PASS"
echo -e "  ${RED}Failed:${RESET}  $FAIL"
echo -e "  ${YELLOW}Warnings:${RESET} $WARN"
echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}${BOLD}RESULT: FAIL, $FAIL check(s) did not pass.${RESET}"
  exit 1
else
  echo -e "${GREEN}${BOLD}RESULT: PASS${RESET}"
  exit 0
fi
