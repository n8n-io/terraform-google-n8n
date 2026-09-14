#!/usr/bin/env bash
# Credential-free regression check for the pinned n8n Helm chart
# (var.n8n_chart_version / var.n8n_chart_repository in variables.tf).
#
# Renders the exact chart this module installs with a synthetic values
# fixture representative of what helm_release.n8n (n8n.tf) sets, using only
# `helm template`, no Terraform, no Kubernetes cluster, no cloud credentials.
# It proves the *chart* renders these value fragments the way the module
# assumes; it does not prove the module's Terraform expressions compute the
# right fragment (that is covered by the mocked plan-time `terraform test`
# suite) and it is not a live Helm upgrade or a proof of runtime behavior.
#
# What this checks, matching task 1.3:
#   - The pinned chart renders cleanly with no credentials.
#   - Floor seeding: multiMain.replicas / queueMode.workerReplicaCount /
#     webhookProcessor.replicaCount reach the main/worker/webhook-processor
#     Deployments' `replicas` field unmodified.
#   - service.annotations (the BackendConfig annotation the module sets when
#     create_ingress = true) reaches BOTH the main and the webhook-processor
#     Service, not just the main one, resolving the open question flagged as
#     a smoke-test follow-up in n8n.tf's service.annotations comment.
#   - executions.data reaches the four EXECUTIONS_DATA_SAVE_* env vars on both
#     containers that render them (main, worker; the chart does not include
#     executions env on the webhook-processor container).
#   - The self-check below proves an intentionally wrong expected value is
#     actually caught (a real assertion failure), not a check that always
#     passes.
#
# Usage: tests/scripts/check-n8n-chart.sh
# Requires: helm (any version able to pull OCI charts), no other tools.

set -euo pipefail

cd "$(dirname "$0")/../.."

CHART_REPOSITORY="oci://ghcr.io/n8n-io/n8n-helm-chart"
CHART_NAME="n8n"
CHART_VERSION="1.10.1"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

# ── Synthetic values fixture ─────────────────────────────────────────────────
# Deliberately distinct, non-default numbers (2 / 3 / 1) for the three replica
# fields so a check that silently compares the chart's own defaults against
# themselves cannot pass by accident. Coordinates (hosts, secret names) are
# synthetic placeholders; no resource in this repo is asked to exist.
# This mirrors the input-derived fragments this change shares as locals
# (locals.tf's "n8n Helm chart value fragments"), not the full Helm values
# blob helm_release.n8n builds (which also carries resource-derived Secret
# coordinates that only resolve during a real apply).
cat >"$WORKDIR/fixture-values.yaml" <<'EOF'
multiMain:
  enabled: true
  replicas: 2
queueMode:
  enabled: true
  workerReplicaCount: 3
  workerConcurrency: 5
webhookProcessor:
  enabled: true
  replicaCount: 1
  disableProductionWebhooksOnMainProcess: true
database:
  type: postgresdb
  useExternal: true
  host: synthetic-postgres.internal
  port: 5432
  database: n8n
  schema: public
  user: n8n
  passwordSecret:
    name: synthetic-db-secret
    key: password
redis:
  enabled: true
  useExternal: true
  host: synthetic-redis.internal
  port: 6379
  tls: false
  username: ""
  prefix: ""
service:
  type: ClusterIP
  port: 5678
  annotations:
    cloud.google.com/backend-config: '{"default":"n8n-backendconfig"}'
executions:
  data:
    saveOnError: all
    saveOnSuccess: all
    saveOnProgress: false
    saveManualExecutions: true
secretRefs:
  existingSecret: synthetic-core-secret
license:
  enabled: true
  activationKey: ""
  existingSecret:
    name: ""
    key: license-key
s3:
  enabled: true
  bucket:
    name: synthetic-bucket
    region: auto
    host: storage.googleapis.com
  auth:
    autoDetect: false
    accessKeyId: synthetic-access-id
    secretAccessKeySecret:
      name: synthetic-s3-secret
      key: accessSecret
  storage:
    mode: s3
    availableModes: "filesystem,s3"
    forcePathStyle: true
EOF

echo "==> helm template ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-values.yaml" \
  >"$WORKDIR/rendered.yaml" 2>"$WORKDIR/helm-stderr.log"; then
  cat "$WORKDIR/helm-stderr.log" >&2
  fail "helm template exited non-zero; see stderr above. This chart version/repository may no longer exist, need credentials it did not get, or reject the fixture values."
  echo "Failures: $FAILURES" >&2
  exit 1
fi
pass "helm template rendered ${CHART_NAME}:${CHART_VERSION} with no credentials"

RENDERED="$WORKDIR/rendered.yaml"

# assert_deployment_replicas <deployment-name> <expected-replica-count>
# Reads the `replicas:` field from the named Deployment's manifest block.
# Each Deployment's manifest is delimited by its own `kind: Deployment` /
# `name: <deployment-name>` pair followed later by the next `---` document
# separator helm inserts between rendered manifests.
assert_deployment_replicas() {
  local name="$1" expected="$2" actual
  actual="$(awk -v name="$name" '
    /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
    in_deploy && $0 == "  name: " name { found_name = 1; next }
    in_deploy && found_name && /^  replicas:/ { print $2; exit }
    /^---$/ { in_deploy = 0; found_name = 0 }
  ' "$RENDERED")"

  if [ "$actual" = "$expected" ]; then
    pass "Deployment/${name} replicas == ${expected}"
  else
    fail "Deployment/${name} replicas: expected ${expected}, got '${actual:-<not found>}'"
  fi
}

# assert_service_annotation <service-name> <annotation-key> <expected-value>
# Confirms the annotation appears within the named Service's own manifest
# block, not merely somewhere in the combined rendered output.
assert_service_annotation() {
  local name="$1" key="$2" expected="$3" block
  block="$(awk -v name="$name" '
    /^kind: Service$/ { in_svc = 1; found_name = 0; buf = ""; next }
    in_svc && $0 == "  name: " name { found_name = 1 }
    in_svc && found_name { buf = buf $0 "\n" }
    /^---$/ { if (found_name) { print buf; exit }; in_svc = 0; found_name = 0; buf = "" }
    END { if (found_name) print buf }
  ' "$RENDERED")"

  if echo "$block" | grep -qF "${key}: '${expected}'" || echo "$block" | grep -qF "${key}: \"${expected}\""; then
    pass "Service/${name} carries annotation ${key}"
  else
    fail "Service/${name} is missing annotation ${key}=${expected}"
  fi
}

# assert_env_count <env-name> <expected-occurrences> <expected-value>
# EXECUTIONS_DATA_SAVE_* is emitted once per container that includes the
# chart's executionsEnv helper (main, worker; not webhook-processor, see
# templates/deployment-webhook-processor.yaml). Counts occurrences across the
# whole rendered output and checks the value on each.
assert_env_count() {
  local env_name="$1" expected_count="$2" expected_value="$3" actual_count
  actual_count="$(awk -v name="$env_name" '
    $0 ~ "- name: " name "$" { count++ }
    END { print count+0 }
  ' "$RENDERED")"

  if [ "$actual_count" != "$expected_count" ]; then
    fail "${env_name}: expected ${expected_count} occurrence(s), found ${actual_count}"
    return
  fi

  local mismatched
  mismatched="$(awk -v name="$env_name" -v expected="value: \"${expected_value}\"" '
    $0 ~ "- name: " name "$" { getline v; if (v != "              " expected && v != "            " expected) print v }
  ' "$RENDERED")"

  if [ -n "$mismatched" ]; then
    fail "${env_name}: found an occurrence with an unexpected value: ${mismatched}"
  else
    pass "${env_name} == \"${expected_value}\" on all ${expected_count} rendered container(s)"
  fi
}

assert_deployment_replicas "n8n-main" "2"
assert_deployment_replicas "n8n-webhook-processor" "1"
assert_deployment_replicas "n8n-worker" "3"

assert_service_annotation "n8n-main" "cloud.google.com/backend-config" '{"default":"n8n-backendconfig"}'
assert_service_annotation "n8n-webhook-processor" "cloud.google.com/backend-config" '{"default":"n8n-backendconfig"}'

assert_env_count "EXECUTIONS_DATA_SAVE_ON_ERROR" "2" "all"
assert_env_count "EXECUTIONS_DATA_SAVE_ON_SUCCESS" "2" "all"
assert_env_count "EXECUTIONS_DATA_SAVE_ON_PROGRESS" "2" "false"
assert_env_count "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS" "2" "true"

# ── Self-check: prove a wrong expected value is actually caught ─────────────
# Runs one assertion with a deliberately wrong expected replica count in a
# subshell (so its FAILURES increment does not pollute the real run) and
# confirms the helper reports it as a failure, not a false pass. This is the
# "fails on an intentionally wrong expected value" requirement from task 1.3:
# it demonstrates the assertion mechanism itself has teeth, every time this
# script runs, rather than only when someone remembers to break it by hand.
SELFTEST_OUTPUT="$(
  FAILURES=0
  fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
  pass() { echo "PASS: $1"; }
  assert_deployment_replicas() {
    local name="$1" expected="$2" actual
    actual="$(awk -v name="$name" '
      /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
      in_deploy && $0 == "  name: " name { found_name = 1; next }
      in_deploy && found_name && /^  replicas:/ { print $2; exit }
      /^---$/ { in_deploy = 0; found_name = 0 }
    ' "$RENDERED")"
    if [ "$actual" = "$expected" ]; then
      pass "Deployment/${name} replicas == ${expected}"
    else
      fail "Deployment/${name} replicas: expected ${expected}, got '${actual:-<not found>}'"
    fi
  }
  assert_deployment_replicas "n8n-main" "999"
  echo "FAILURES=$FAILURES"
)"

if echo "$SELFTEST_OUTPUT" | grep -q "^FAILURES=1$"; then
  pass "self-check: an intentionally wrong expected value (main replicas == 999) is correctly caught"
else
  fail "self-check: an intentionally wrong expected value was NOT caught; the assertion helpers cannot be trusted. Output: ${SELFTEST_OUTPUT}"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "check-n8n-chart.sh: ${FAILURES} check(s) failed" >&2
  exit 1
fi

echo "check-n8n-chart.sh: all checks passed"
