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
#     executions env on the webhook-processor container), for both the
#     default all/all/false/true policy and a mixed non-default policy.
#   - database.ssl with a PostgreSQL CA renders DB_POSTGRESDB_SSL_CA into the
#     chart ConfigMap and onto every role, with no duplicate of the module's
#     own DB_POSTGRESDB_SSL_* env entries, and a changed CA changes each
#     role's checksum/config annotation (so a CA change rolls the pods).
#   - The self-check below proves an intentionally wrong expected value is
#     actually caught (a real assertion failure), not a check that always
#     passes.
#
# Usage: tests/scripts/check-n8n-chart.sh
# Requires: helm (any version able to pull OCI charts) and python3 (used by
# tests/scripts/lib/tf-defaults.sh to read the module's chart pins).

set -euo pipefail

cd "$(dirname "$0")/../.."

CHART_REPOSITORY="oci://ghcr.io/n8n-io/n8n-helm-chart"
CHART_NAME="n8n"
CHART_VERSION="1.14.0"

# Fail fast if the pins above drift from the module's own chart defaults.
# Several assertions below (e.g. the graceful shutdown timeout default compared
# against local.n8n_chart_default_graceful_shutdown_timeout) only prove
# anything about the module when this script renders the chart it installs.
# shellcheck source=lib/tf-defaults.sh
source tests/scripts/lib/tf-defaults.sh
MODULE_CHART_VERSION="$(tf_var_default variables.tf n8n_chart_version)" || MODULE_CHART_VERSION="<unreadable>"
MODULE_CHART_REPOSITORY="$(tf_var_default variables.tf n8n_chart_repository)" || MODULE_CHART_REPOSITORY="<unreadable>"
if [[ "$MODULE_CHART_VERSION" != "$CHART_VERSION" || "$MODULE_CHART_REPOSITORY" != "$CHART_REPOSITORY" ]]; then
  echo "FAIL: this script pins ${CHART_REPOSITORY} ${CHART_VERSION}, but variables.tf defaults to ${MODULE_CHART_REPOSITORY} ${MODULE_CHART_VERSION}; update CHART_REPOSITORY/CHART_VERSION here" >&2
  exit 1
fi

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

# n8n deprecated N8N_AVAILABLE_BINARY_DATA_MODES and logs a warning whenever
# it is set, even though n8n 2.x otherwise ignores it. Chart 1.14.0 stopped
# rendering it (n8n-hosting#185), and the module never sends
# s3.storage.availableModes (n8n.tf). This proves the pinned chart does not
# bring it back on its own. The S3 env block
# must have rendered first, or the absence check would pass vacuously.
if ! grep -q -- '- name: N8N_DEFAULT_BINARY_DATA_MODE$' "$RENDERED"; then
  fail "S3 fixture did not render N8N_DEFAULT_BINARY_DATA_MODE; the N8N_AVAILABLE_BINARY_DATA_MODES absence check below would pass vacuously"
elif awk '/- name: N8N_AVAILABLE_BINARY_DATA_MODES$/ { found = 1 } END { exit !found }' "$RENDERED"; then
  fail "N8N_AVAILABLE_BINARY_DATA_MODES is rendered; n8n deprecated it and warns on every start"
else
  pass "N8N_AVAILABLE_BINARY_DATA_MODES absent from every rendered container (S3 env block rendered)"
fi

# The legacy WEBHOOK_URL is deprecated too (n8n 2.30.0). Chart 1.14.0 renamed
# its own ConfigMap key to N8N_WEBHOOK_URL (n8n-hosting#184), so the chart
# must not render the legacy name itself; the module adds it through
# config.extraEnv only for images that may predate 2.30.0
# (local.n8n_webhook_url_env, asserted in tests/kubernetes_ownership.tftest.hcl).
if grep -qE -- '(- name: |key: |^  )WEBHOOK_URL(:|$)' "$RENDERED"; then
  fail "the chart renders the deprecated WEBHOOK_URL itself; local.n8n_webhook_url_env can no longer control it"
else
  pass "the chart renders no legacy WEBHOOK_URL of its own"
fi

# ── Mixed execution-save policy (task 6.1) ──────────────────────────────────
# A second render of the same fixture with a non-default, non-uniform
# executions.data policy (local.n8n_executions_data's shape once
# n8n_executions_data_save_on_success/on_error/on_progress/manual_executions
# are all set away from their defaults), proving the chart renders each of
# the four values independently rather than only ever exercising the all/
# all/false/true default combination above. Webhook-processor is
# deliberately excluded: the chart's executionsEnv helper only renders on
# main and worker (templates/deployment-webhook-processor.yaml), matching
# the default-fixture assertion above.
sed 's/^\([[:space:]]*saveOnError: \).*/\1none/; s/^\([[:space:]]*saveOnProgress: \).*/\1true/; s/^\([[:space:]]*saveManualExecutions: \).*/\1false/' \
  "$WORKDIR/fixture-values.yaml" >"$WORKDIR/fixture-mixed-executions.yaml"

echo "==> helm template (mixed execution-save fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-mixed-executions.yaml" \
  >"$WORKDIR/rendered-mixed-executions.yaml" 2>"$WORKDIR/helm-stderr-mixed-executions.log"; then
  cat "$WORKDIR/helm-stderr-mixed-executions.log" >&2
  fail "helm template (mixed execution-save fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the mixed execution-save fixture with no credentials"

  ME_RENDERED="$WORKDIR/rendered-mixed-executions.yaml"

  assert_env_count_in() {
    local file="$1" env_name="$2" expected_count="$3" expected_value="$4" actual_count
    actual_count="$(awk -v name="$env_name" '
      $0 ~ "- name: " name "$" { count++ }
      END { print count+0 }
    ' "$file")"

    if [ "$actual_count" != "$expected_count" ]; then
      fail "${env_name}: expected ${expected_count} occurrence(s), found ${actual_count}"
      return
    fi

    local mismatched
    mismatched="$(awk -v name="$env_name" -v expected="value: \"${expected_value}\"" '
      $0 ~ "- name: " name "$" { getline v; if (v != "              " expected && v != "            " expected) print v }
    ' "$file")"

    if [ -n "$mismatched" ]; then
      fail "${env_name}: found an occurrence with an unexpected value: ${mismatched}"
    else
      pass "${env_name} == \"${expected_value}\" on all ${expected_count} rendered container(s)"
    fi
  }

  assert_env_count_in "$ME_RENDERED" "EXECUTIONS_DATA_SAVE_ON_ERROR" "2" "none"
  assert_env_count_in "$ME_RENDERED" "EXECUTIONS_DATA_SAVE_ON_SUCCESS" "2" "all"
  assert_env_count_in "$ME_RENDERED" "EXECUTIONS_DATA_SAVE_ON_PROGRESS" "2" "true"
  assert_env_count_in "$ME_RENDERED" "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS" "2" "false"
fi

# ── Single-main topology (task 3.1/3.3) ─────────────────────────────────────
# A second render with the default fragments locals.tf computes for single-main
# (n8n_single_main=true, election override null): multiMain.enabled=false, replicaCount=1,
# strategy={type: Recreate}, and pdb.minAvailable=0. Proves the chart actually
# turns those fragments into a Recreate main Deployment and a permissive main
# PDB, and leaves worker/webhook replicas and strategy untouched.
cat >"$WORKDIR/fixture-single-main.yaml" <<'EOF'
multiMain:
  enabled: false
  replicas: 1
replicaCount: 1
strategy:
  type: Recreate
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
hpa:
  main:
    enabled: true
    minReplicas: 1
    maxReplicas: 1
    targetCPUUtilizationPercentage: 60
pdb:
  enabled: true
  minAvailable: 0
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
    forcePathStyle: true
EOF

echo "==> helm template (single-main fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-single-main.yaml" \
  >"$WORKDIR/rendered-single-main.yaml" 2>"$WORKDIR/helm-stderr-single-main.log"; then
  cat "$WORKDIR/helm-stderr-single-main.log" >&2
  fail "helm template (single-main fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the single-main fixture with no credentials"

  SM_RENDERED="$WORKDIR/rendered-single-main.yaml"

  # assert_deployment_strategy <deployment-name> <expected-type-or-empty>
  # Reads the `strategy.type:` field from the named Deployment. An expected
  # value of "" asserts the Deployment has NO strategy block at all (the
  # chart's `with .Values.strategy` guard omits the whole key when empty).
  assert_deployment_strategy() {
    local name="$1" expected="$2" actual
    actual="$(awk -v name="$name" '
      /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
      in_deploy && $0 == "  name: " name { found_name = 1; next }
      in_deploy && found_name && /^  strategy:/ { in_strategy = 1; next }
      in_deploy && found_name && in_strategy && /^    type:/ { print $2; exit }
      in_deploy && found_name && /^  selector:/ { exit }
      /^---$/ { in_deploy = 0; found_name = 0; in_strategy = 0 }
    ' "$SM_RENDERED")"
    if [ "$actual" = "$expected" ]; then
      pass "Deployment/${name} strategy.type == '${expected:-<absent>}'"
    else
      fail "Deployment/${name} strategy.type: expected '${expected:-<absent>}', got '${actual:-<absent>}'"
    fi
  }

  # assert_pdb_min_available <expected>
  # This chart renders exactly one PDB (main only), so no name filter is
  # needed.
  assert_pdb_min_available() {
    local expected="$1" actual
    actual="$(awk '
      /^kind: PodDisruptionBudget$/ { in_pdb = 1; next }
      in_pdb && /^  minAvailable:/ { print $2; exit }
    ' "$SM_RENDERED")"
    if [ "$actual" = "$expected" ]; then
      pass "PodDisruptionBudget minAvailable == ${expected}"
    else
      fail "PodDisruptionBudget minAvailable: expected ${expected}, got '${actual:-<not found>}'"
    fi
  }

  SM_MAIN_REPLICAS="$(awk '
    /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
    in_deploy && $0 == "  name: n8n-main" { found_name = 1; next }
    in_deploy && found_name && /^  replicas:/ { print $2; exit }
    /^---$/ { in_deploy = 0; found_name = 0 }
  ' "$SM_RENDERED")"
  if [ "$SM_MAIN_REPLICAS" = "1" ]; then
    pass "single-main Deployment/n8n-main replicas == 1"
  else
    fail "single-main Deployment/n8n-main replicas: expected 1, got '${SM_MAIN_REPLICAS:-<not found>}'"
  fi

  assert_deployment_strategy "n8n-main" "Recreate"
  assert_deployment_strategy "n8n-worker" ""
  assert_deployment_strategy "n8n-webhook-processor" ""
  assert_pdb_min_available "0"

  # No disabled scalers: worker/webhook queue-mode Deployments and the
  # multi-main-only main HPA/Service still render at their configured
  # replica counts, single-main only changes the main rollout/PDB/HPA
  # ceiling, not whether workers or webhook processors exist.
  SM_WORKER_REPLICAS="$(awk '
    /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
    in_deploy && $0 == "  name: n8n-worker" { found_name = 1; next }
    in_deploy && found_name && /^  replicas:/ { print $2; exit }
    /^---$/ { in_deploy = 0; found_name = 0 }
  ' "$SM_RENDERED")"
  if [ "$SM_WORKER_REPLICAS" = "3" ]; then
    pass "single-main fixture still renders Deployment/n8n-worker at its configured replica count (no disabled scalers)"
  else
    fail "single-main fixture's Deployment/n8n-worker replicas: expected 3, got '${SM_WORKER_REPLICAS:-<not found>}'"
  fi

  # Stage one changes election only, retaining the one-replica safeguards.
  # This is a render assertion, not proof of upgrade ordering or runtime safety.
  cat >"$WORKDIR/fixture-election-staging.yaml" <<'EOF'
config:
  extraEnv:
    - name: N8N_MULTI_MAIN_SETUP_ENABLED
      value: "true"
EOF
  if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
    --version "${CHART_VERSION}" \
    --namespace n8n-chart-check \
    -f "$WORKDIR/fixture-single-main.yaml" \
    -f "$WORKDIR/fixture-election-staging.yaml" \
    --set keda.enabled=true \
    >"$WORKDIR/rendered-election-staging.yaml" 2>"$WORKDIR/helm-stderr-election-staging.log"; then
    cat "$WORKDIR/helm-stderr-election-staging.log" >&2
    fail "helm template (election staging) exited non-zero"
  else
    DEFAULT_RENDERED="$RENDERED"
    RENDERED="$WORKDIR/rendered-election-staging.yaml"
    SM_RENDERED="$RENDERED"
    assert_deployment_replicas "n8n-main" "1"
    # keda.enabled=true with the chart's default worker triggers makes the
    # chart (>= 1.13.0, n8n-hosting#201) omit the worker Deployment's
    # `replicas` and leave the count to the ScaledObject; the webhook
    # processor below has no chart-side owner here and keeps its count.
    STAGING_WORKER_REPLICAS="$(awk '
      /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
      in_deploy && $0 == "  name: n8n-worker" { found_name = 1; next }
      in_deploy && found_name && /^  replicas:/ { print $2; exit }
      /^---$/ { in_deploy = 0; found_name = 0 }
    ' "$RENDERED")"
    if [ -z "$STAGING_WORKER_REPLICAS" ]; then
      pass "election staging (keda on): Deployment/n8n-worker renders no replicas field (KEDA owns the count)"
    else
      fail "election staging (keda on): Deployment/n8n-worker still renders replicas: ${STAGING_WORKER_REPLICAS}"
    fi
    assert_deployment_replicas "n8n-webhook-processor" "1"
    assert_deployment_strategy "n8n-main" "Recreate"
    assert_deployment_strategy "n8n-worker" ""
    assert_deployment_strategy "n8n-webhook-processor" ""
    assert_pdb_min_available "0"

    STAGING_HPA="$(awk '
      /^kind: HorizontalPodAutoscaler$/ { in_hpa = 1; next }
      in_hpa && /^  name: n8n-main$/ { main = 1 }
      in_hpa && main && /^  (minReplicas|maxReplicas):/ { print $1, $2 }
      /^---$/ { in_hpa = 0; main = 0 }
    ' "$RENDERED")"
    if [ "$(printf '%s\n' "$STAGING_HPA" | sort)" = "$(printf 'maxReplicas: 1\nminReplicas: 1')" ]; then
      pass "election staging main HPA min/max == 1/1"
    else
      fail "election staging main HPA must have min/max 1/1: $STAGING_HPA"
    fi

    # Chart multiMain stays disabled; runtime election is a literal on all
    # three n8n roles via extraEnv. No ConfigMap election reference is emitted.
    assert_env_count "N8N_MULTI_MAIN_SETUP_ENABLED" "3" "true"
    STAGING_MAIN_ELECTION="$(awk '
      /^kind: Deployment$/ { in_deploy = 1; next }
      in_deploy && /^  name: n8n-main$/ { main = 1 }
      in_deploy && main && /- name: N8N_MULTI_MAIN_SETUP_ENABLED$/ {
        getline
        if ($1 == "value:" && $2 == "\"true\"") print "enabled"
      }
      /^---$/ { in_deploy = 0; main = 0 }
    ' "$RENDERED")"
    if [ "$STAGING_MAIN_ELECTION" = "enabled" ] && ! grep -q 'key: N8N_MULTI_MAIN_SETUP_ENABLED' "$RENDERED"; then
      pass "election staging main has literal election enabled without chart multiMain references"
    else
      fail "election staging must use the literal flag in the main pod, not chart multiMain"
    fi
    RENDERED="$DEFAULT_RENDERED"
    SM_RENDERED="$WORKDIR/rendered-single-main.yaml"
  fi
fi

# ── Return to multi-main (task 3.3) ─────────────────────────────────────────
# Confirms the final main Deployment rendering at two replicas and normal
# chart election references. Reusing the independent default render does NOT
# test an upgrade or prove that the old ReplicaSet was replaced before scaling.
assert_deployment_strategy_absent_in_default() {
  local actual
  actual="$(awk '
    /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
    in_deploy && $0 == "  name: n8n-main" { found_name = 1; next }
    in_deploy && found_name && /^  strategy:/ { print "present"; exit }
    in_deploy && found_name && /^  selector:/ { exit }
    /^---$/ { in_deploy = 0; found_name = 0 }
  ' "$RENDERED")"
  if [ -z "$actual" ]; then
    pass "multi-main Deployment/n8n-main has no strategy override (chart default)"
  else
    fail "multi-main Deployment/n8n-main unexpectedly has a strategy override"
  fi
}
assert_deployment_strategy_absent_in_default

MM_MAIN_ELECTION_REF="$(awk '
  /^kind: Deployment$/ { in_deploy = 1; next }
  in_deploy && /^  name: n8n-main$/ { main = 1 }
  in_deploy && main && /- name: N8N_MULTI_MAIN_SETUP_ENABLED$/ {
    for (i = 0; i < 4; i++) {
      getline
      if ($1 == "valueFrom:") value_from = 1
      if ($1 == "configMapKeyRef:") ref = 1
      if ($1 == "name:" && $2 == "n8n") name = 1
      if ($1 == "key:" && $2 == "N8N_MULTI_MAIN_SETUP_ENABLED") key = 1
    }
    if (value_from && ref && name && key) print "referenced"
  }
  /^---$/ { in_deploy = 0; main = 0 }
' "$RENDERED")"
if [ "$MM_MAIN_ELECTION_REF" = "referenced" ] &&
  [ "$(grep -c -- '- name: N8N_MULTI_MAIN_SETUP_ENABLED$' "$RENDERED" || true)" = "1" ] &&
  [ "$(grep -c '^  N8N_MULTI_MAIN_SETUP_ENABLED: "true"$' "$RENDERED" || true)" = "1" ]; then
  pass "multi-main uses the chart election ConfigMap reference on main only"
else
  fail "multi-main must use the chart election ConfigMap reference on main only, without staging literals"
fi

# ── Redis command/Bull prefix synchronization (task 7.1) ───────────────────
# A third render with redis.prefix set (the chart's Bull-queue prefix) and
# config.extraEnv carrying N8N_REDIS_KEY_PREFIX (the module's command-channel
# override, n8n.tf), both set to the same var.redis_key_prefix value. Proves
# the chart actually renders QUEUE_BULL_PREFIX from redis.prefix and
# N8N_REDIS_KEY_PREFIX from config.extraEnv on every container that reads
# config.extraEnv (main, worker, webhook-processor; see
# templates/deployment-*.yaml's `with .Values.config.extraEnv` guard), so a
# caller-set prefix reaches n8n's command channel and its Bull queue keys
# together, not just one of the two.
cat >"$WORKDIR/fixture-redis-prefix.yaml" <<'EOF'
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
  prefix: "myprefix"
config:
  extraEnv:
    - name: N8N_REDIS_KEY_PREFIX
      value: myprefix
service:
  type: ClusterIP
  port: 5678
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
    forcePathStyle: true
EOF

echo "==> helm template (redis-prefix fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-redis-prefix.yaml" \
  >"$WORKDIR/rendered-redis-prefix.yaml" 2>"$WORKDIR/helm-stderr-redis-prefix.log"; then
  cat "$WORKDIR/helm-stderr-redis-prefix.log" >&2
  fail "helm template (redis-prefix fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the redis-prefix fixture with no credentials"

  RP_RENDERED="$WORKDIR/rendered-redis-prefix.yaml"

  # QUEUE_BULL_PREFIX is set once in the rendered ConfigMap's data (from
  # redis.prefix) and consumed via envFrom.configMapKeyRef on every
  # container that reads it (main, worker, webhook-processor), not as a
  # literal `value:` env entry, so it needs its own checks rather than
  # assert_env_count_in (which expects a literal value).
  RP_QUEUE_BULL_PREFIX_CONFIGMAP_VALUE="$(grep -c '^  QUEUE_BULL_PREFIX: "myprefix"$' "$RP_RENDERED" || true)"
  if [ "$RP_QUEUE_BULL_PREFIX_CONFIGMAP_VALUE" = "1" ]; then
    pass "ConfigMap/n8n QUEUE_BULL_PREFIX == \"myprefix\""
  else
    fail "ConfigMap/n8n QUEUE_BULL_PREFIX: expected exactly one occurrence of QUEUE_BULL_PREFIX: \"myprefix\", found ${RP_QUEUE_BULL_PREFIX_CONFIGMAP_VALUE}"
  fi

  RP_QUEUE_BULL_PREFIX_ENV_COUNT="$(grep -c '^            - name: QUEUE_BULL_PREFIX$' "$RP_RENDERED" || true)"
  if [ "$RP_QUEUE_BULL_PREFIX_ENV_COUNT" = "3" ]; then
    pass "QUEUE_BULL_PREFIX sourced from the ConfigMap on all 3 rendered containers"
  else
    fail "QUEUE_BULL_PREFIX env entry: expected 3 occurrences (main/worker/webhook-processor), found ${RP_QUEUE_BULL_PREFIX_ENV_COUNT}"
  fi

  # N8N_REDIS_KEY_PREFIX passes through config.extraEnv's raw `with`/toYaml
  # block (unlike the chart's own executionsEnv helper, which quotes its
  # values), so a plain scalar like "myprefix" round-trips unquoted.
  RP_COMMAND_PREFIX_COUNT="$(awk '
    $0 ~ "- name: N8N_REDIS_KEY_PREFIX$" { getline v; if (v == "              value: myprefix" || v == "            value: myprefix") count++ }
    END { print count+0 }
  ' "$RP_RENDERED")"
  if [ "$RP_COMMAND_PREFIX_COUNT" = "3" ]; then
    pass "N8N_REDIS_KEY_PREFIX == myprefix on all 3 rendered containers"
  else
    fail "N8N_REDIS_KEY_PREFIX: expected 3 occurrence(s) with value myprefix, found ${RP_COMMAND_PREFIX_COUNT}"
  fi
fi

# ── Canonical editor/webhook URLs (task 19.1) ───────────────────────────────
# A fourth render with config.extraEnv carrying WEBHOOK_URL, N8N_WEBHOOK_URL,
# and N8N_EDITOR_BASE_URL (n8n.tf's extraEnv block, sourced from
# local.effective_webhook_url and https://<n8n_fqdn> respectively). This is
# the legacy-image shape: WEBHOOK_URL is only in local.n8n_webhook_url_env when
# the image may predate n8n 2.30.0, so the fixture covers the larger list. Using
# distinct editor and webhook hosts so a passing render proves the chart
# keeps the two independent rather than collapsing to one host, on every
# container that reads config.extraEnv (main, worker, webhook-processor).
cat >"$WORKDIR/fixture-canonical-urls.yaml" <<'EOF'
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
config:
  extraEnv:
    - name: WEBHOOK_URL
      value: https://hooks.example.test
    - name: N8N_WEBHOOK_URL
      value: https://hooks.example.test
    - name: N8N_EDITOR_BASE_URL
      value: https://editor.example.test
service:
  type: ClusterIP
  port: 5678
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
    forcePathStyle: true
EOF

echo "==> helm template (canonical-urls fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-canonical-urls.yaml" \
  >"$WORKDIR/rendered-canonical-urls.yaml" 2>"$WORKDIR/helm-stderr-canonical-urls.log"; then
  cat "$WORKDIR/helm-stderr-canonical-urls.log" >&2
  fail "helm template (canonical-urls fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the canonical-urls fixture with no credentials"

  CU_RENDERED="$WORKDIR/rendered-canonical-urls.yaml"

  # config.extraEnv passes through the chart's raw with/toYaml block (see the
  # N8N_REDIS_KEY_PREFIX check above), so these scalars round-trip unquoted.
  assert_extraenv_count() {
    local env_name="$1" expected_count="$2" expected_value="$3" actual_count
    actual_count="$(awk -v name="$env_name" -v expected="value: ${expected_value}" '
      $0 ~ "- name: " name "$" { getline v; if (v == "              " expected || v == "            " expected) count++ }
      END { print count+0 }
    ' "$CU_RENDERED")"
    if [ "$actual_count" = "$expected_count" ]; then
      pass "${env_name} == ${expected_value} on all ${expected_count} rendered container(s)"
    else
      fail "${env_name}: expected ${expected_count} occurrence(s) with value ${expected_value}, found ${actual_count}"
    fi
  }

  assert_extraenv_count "WEBHOOK_URL" "3" "https://hooks.example.test"
  assert_extraenv_count "N8N_WEBHOOK_URL" "3" "https://hooks.example.test"
  assert_extraenv_count "N8N_EDITOR_BASE_URL" "3" "https://editor.example.test"
fi

# ── Caller-managed volumes coexist with the managed Redis CA (task 10.2) ────
# A render combining the module's own Redis CA secret volume/mount with
# caller-declared ConfigMap, Secret, and PVC volumes (local.
# n8n_caller_extra_volumes/n8n_caller_extra_volume_mounts in locals.tf,
# concatenated after the Redis CA entry in n8n.tf), exactly as multiple
# n8n_extra_volumes sources would render together. `helm template` needs no
# cluster and never looks up the named ConfigMap/Secret/PVC, so a passing
# render here proves the module creates and reads none of the caller's
# referenced objects; it only emits references to them.
cat >"$WORKDIR/fixture-caller-volumes.yaml" <<'EOF'
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
extraVolumes:
  - name: redis-ca
    secret:
      secretName: synthetic-redis-ca
      items:
        - key: ca.crt
          path: ca.crt
  - name: custom-nodes
    configMap:
      name: synthetic-caller-configmap
  - name: caller-secret-vol
    secret:
      secretName: synthetic-caller-secret
      defaultMode: 288
  - name: caller-pvc-vol
    persistentVolumeClaim:
      claimName: synthetic-caller-pvc
extraVolumeMounts:
  - name: redis-ca
    mountPath: /etc/n8n-certs/redis-ca.crt
    subPath: ca.crt
    readOnly: true
  - name: custom-nodes
    mountPath: /opt/n8n-nodes
    readOnly: true
  - name: caller-secret-vol
    mountPath: /etc/n8n/caller-secret
    readOnly: true
  - name: caller-pvc-vol
    mountPath: /data/caller-pvc
    readOnly: false
service:
  type: ClusterIP
  port: 5678
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
    forcePathStyle: true
EOF

echo "==> helm template (caller-volumes fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-caller-volumes.yaml" \
  >"$WORKDIR/rendered-caller-volumes.yaml" 2>"$WORKDIR/helm-stderr-caller-volumes.log"; then
  cat "$WORKDIR/helm-stderr-caller-volumes.log" >&2
  fail "helm template (caller-volumes fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the caller-volumes fixture with no credentials (no cluster contacted, no caller object created or read)"

  CV_RENDERED="$WORKDIR/rendered-caller-volumes.yaml"

  # assert_name_count_in <volume-or-mount-name> <expected-occurrences>
  # Each of the 4 declared volume names should appear once per Deployment
  # (main, worker, webhook-processor) in both the pod's volumes list and its
  # container's volumeMounts list, since extraVolumes/extraVolumeMounts are
  # top-level chart values applied to all three (verified against
  # templates/deployment-*.yaml). toYaml renders map keys alphabetically, so
  # "name:" is not always the first ("- "-prefixed) key of its list item
  # (e.g. configMap/mountPath sort before name); match the bare "name: X"
  # line regardless of leading "- ".
  assert_name_count_in() {
    local file="$1" needle="$2" expected="$3" actual
    actual="$(grep -c -- "name: ${needle}$" "$file" || true)"
    if [ "$actual" = "$expected" ]; then
      pass "\"name: ${needle}\" occurs ${expected} time(s) (volumes + volumeMounts across main/worker/webhook-processor)"
    else
      fail "\"name: ${needle}\": expected ${expected} occurrence(s), found ${actual}"
    fi
  }

  # 3 roles x 2 (one volumes entry + one volumeMounts entry) = 6 for each name.
  assert_name_count_in "$CV_RENDERED" "redis-ca" "6"
  assert_name_count_in "$CV_RENDERED" "custom-nodes" "6"
  assert_name_count_in "$CV_RENDERED" "caller-secret-vol" "6"
  assert_name_count_in "$CV_RENDERED" "caller-pvc-vol" "6"

  CV_PVC_CLAIM_COUNT="$(grep -c 'claimName: synthetic-caller-pvc' "$CV_RENDERED" || true)"
  if [ "$CV_PVC_CLAIM_COUNT" = "3" ]; then
    pass "caller PVC claimName referenced on all 3 rendered pod specs"
  else
    fail "caller PVC claimName: expected 3 occurrences, found ${CV_PVC_CLAIM_COUNT}"
  fi

  CV_SECRET_DEFAULT_MODE_COUNT="$(grep -c 'defaultMode: 288' "$CV_RENDERED" || true)"
  if [ "$CV_SECRET_DEFAULT_MODE_COUNT" = "3" ]; then
    pass "caller Secret volume's decimal defaultMode (288, converted from octal 0440) reaches all 3 rendered pod specs"
  else
    fail "caller Secret volume defaultMode: expected 3 occurrences of 288, found ${CV_SECRET_DEFAULT_MODE_COUNT}"
  fi
fi

# ── PostgreSQL CA through the chart's database.ssl.ca ──────────────────────
# Mirrors what helm_release.n8n (n8n.tf) renders when
# db_postgresdb_ssl_reject_unauthorized = true and db_postgresdb_ssl_ca_pem is
# set: local.n8n_database_ssl_values merged into `database`, plus the
# DB_POSTGRESDB_SSL_* entries from local.n8n_postgres_ssl_env in
# config.extraEnv. The mocked terraform test suite asserts those locals; this
# render proves the chart:
#   - puts the CA in its ConfigMap as DB_POSTGRESDB_SSL_CA and renders no
#     DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED of its own,
#   - sources DB_POSTGRESDB_SSL_CA on every role, next to exactly one of each
#     module-owned DB_POSTGRESDB_SSL_* entry,
#   - changes each role's checksum/config annotation when the CA changes,
#     which is what rolls the pods and lets an atomic rollback restore the CA.
pg_ca_fixture() {
  printf '%s\n' \
    'database:' \
    '  ssl:' \
    '    enabled: true' \
    '    rejectUnauthorized: true' \
    "    ca: \"-----BEGIN CERTIFICATE-----\\n$1\\n-----END CERTIFICATE-----\"" \
    'config:' \
    '  extraEnv:' \
    '    - name: DB_POSTGRESDB_SSL_ENABLED' \
    '      value: "true"' \
    '    - name: DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED' \
    '      value: "true"'
}
pg_ca_fixture "U1lOVEhFVElDLUNBLUE=" >"$WORKDIR/fixture-postgres-ca-a.yaml"
pg_ca_fixture "U1lOVEhFVElDLUNBLUI=" >"$WORKDIR/fixture-postgres-ca-b.yaml"

PG_RENDER_OK=1
for pg_variant in a b; do
  echo "==> helm template (postgres-ca-${pg_variant} fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
  if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
    --version "${CHART_VERSION}" \
    --namespace n8n \
    -f "$WORKDIR/fixture-values.yaml" \
    -f "$WORKDIR/fixture-postgres-ca-${pg_variant}.yaml" \
    >"$WORKDIR/rendered-postgres-ca-${pg_variant}.yaml" 2>"$WORKDIR/helm-stderr-postgres-ca-${pg_variant}.log"; then
    fail "helm template (postgres-ca-${pg_variant} fixture) failed: $(cat "$WORKDIR/helm-stderr-postgres-ca-${pg_variant}.log")"
    PG_RENDER_OK=0
  fi
done

if [ "$PG_RENDER_OK" = "1" ]; then
  pass "helm template rendered both postgres-ca fixtures with no credentials"

  # pg_manifest <rendered-file> <kind> <name>
  # Prints only the named manifest, so every assertion below is per object: a
  # role with a missing entry cannot be hidden by a duplicate on another role.
  pg_manifest() {
    awk -v kind="kind: $2" -v name="  name: $3" '
      /^---$/ { if (found) exit; in_kind = 0; next }
      $0 == kind { in_kind = 1 }
      in_kind && $0 == name { found = 1 }
      found { print }
    ' "$1"
  }

  PG_CM="$(pg_manifest "$WORKDIR/rendered-postgres-ca-a.yaml" ConfigMap n8n)"
  if [ "$(printf '%s\n' "$PG_CM" | grep -cxF '  DB_POSTGRESDB_SSL_CA: "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"' || true)" = "1" ]; then
    pass "postgres-ca: ConfigMap/n8n renders DB_POSTGRESDB_SSL_CA with the supplied PEM"
  else
    fail "postgres-ca: ConfigMap/n8n does not render DB_POSTGRESDB_SSL_CA with the supplied PEM exactly once"
  fi
  if printf '%s\n' "$PG_CM" | grep -q '^  DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED:'; then
    fail "postgres-ca: ConfigMap/n8n renders its own DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED, duplicating the module's extraEnv entry"
  else
    pass "postgres-ca: ConfigMap/n8n renders no DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED of its own"
  fi

  for pg_role in n8n-main n8n-worker n8n-webhook-processor; do
    pg_block="$(pg_manifest "$WORKDIR/rendered-postgres-ca-a.yaml" Deployment "$pg_role")"
    if [ -z "$pg_block" ]; then
      fail "postgres-ca: Deployment/${pg_role} not found in the render"
      continue
    fi

    # DB_POSTGRESDB_SSL_CA must be sourced from the chart ConfigMap (n8n),
    # key DB_POSTGRESDB_SSL_CA, once.
    pg_ca_refs="$(printf '%s\n' "$pg_block" | awk '
      /- name: DB_POSTGRESDB_SSL_CA$/ { want = 1; cmref = 0; cmname = 0; next }
      want && /configMapKeyRef:$/ { cmref = 1; next }
      want && cmref && /^[[:space:]]+name: n8n$/ { cmname = 1; next }
      want && cmref && cmname && /key: DB_POSTGRESDB_SSL_CA$/ { count++; want = 0 }
      want && /- name: / { want = 0 }
      END { print count+0 }
    ')"
    pg_ca_total="$(printf '%s\n' "$pg_block" | grep -c -- '- name: DB_POSTGRESDB_SSL_CA$' || true)"
    if [ "$pg_ca_total" = "1" ] && [ "$pg_ca_refs" = "1" ]; then
      pass "postgres-ca: Deployment/${pg_role} sources DB_POSTGRESDB_SSL_CA from the chart ConfigMap"
    else
      fail "postgres-ca: Deployment/${pg_role} DB_POSTGRESDB_SSL_CA: expected 1 ConfigMap-sourced entry, found ${pg_ca_total} entries, ${pg_ca_refs} ConfigMap-sourced"
    fi

    # config.extraEnv passes through the chart's raw with/toYaml block, so
    # quoted booleans stay quoted. More than one entry would mean the chart
    # renders its own entry for the same name.
    for pg_env in DB_POSTGRESDB_SSL_ENABLED DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED; do
      pg_env_total="$(printf '%s\n' "$pg_block" | grep -c -- "- name: ${pg_env}$" || true)"
      pg_env_matching="$(printf '%s\n' "$pg_block" | awk -v name="$pg_env" '
        $0 ~ "- name: " name "$" { getline v; sub(/^[[:space:]]+/, "", v); if (v == "value: \"true\"") count++ }
        END { print count+0 }
      ')"
      if [ "$pg_env_total" = "1" ] && [ "$pg_env_matching" = "1" ]; then
        pass "postgres-ca: Deployment/${pg_role} ${pg_env} == \"true\", no duplicate"
      else
        fail "postgres-ca: Deployment/${pg_role} ${pg_env}: expected 1 entry with value \"true\", found ${pg_env_total} entries, ${pg_env_matching} matching"
      fi
    done

    if printf '%s\n' "$pg_block" | grep -q 'DB_POSTGRESDB_SSL_CA_FILE'; then
      fail "postgres-ca: Deployment/${pg_role} still renders DB_POSTGRESDB_SSL_CA_FILE"
    else
      pass "postgres-ca: Deployment/${pg_role} renders no DB_POSTGRESDB_SSL_CA_FILE"
    fi

    # A different CA must change this role's checksum/config annotation.
    pg_sum_a="$(printf '%s\n' "$pg_block" | sed -nE 's/^[[:space:]]+checksum\/config: ([0-9a-f]+)$/\1/p' | head -1)"
    pg_sum_b="$(pg_manifest "$WORKDIR/rendered-postgres-ca-b.yaml" Deployment "$pg_role" | sed -nE 's/^[[:space:]]+checksum\/config: ([0-9a-f]+)$/\1/p' | head -1)"
    if [ -n "$pg_sum_a" ] && [ -n "$pg_sum_b" ] && [ "$pg_sum_a" != "$pg_sum_b" ]; then
      pass "postgres-ca: Deployment/${pg_role} checksum/config changes with the CA"
    else
      fail "postgres-ca: Deployment/${pg_role} checksum/config did not change with the CA (a='${pg_sum_a:-<none>}', b='${pg_sum_b:-<none>}')"
    fi
  done
fi

# ── Offline license activation (N8N_LICENSE_CERT, issue parity with
# terraform-azurerm-n8n#51) ─────────────────────────────────────────────────
# license.existingSecret.name is "" here, same as every other fixture in this
# script: the module's effective_license_secret_name local (locals.tf)
# resolves to the empty string on the n8n_license_cert_secret_ref path, which
# makes the chart's n8n.licenseEnv helper (_environment-helpers.tpl) treat
# existingSecret.name as falsy and emit no N8N_LICENSE_ACTIVATION_KEY at all.
# config.extraEnv instead carries the N8N_LICENSE_CERT secretKeyRef entry the
# module renders from local.n8n_license_cert_env (n8n.tf), proving the chart's
# config.extraEnv (no item-shape restriction in values.schema.json, unlike
# executions.extraEnv) actually accepts and renders a valueFrom.secretKeyRef
# entry, on every pod role.
cat >"$WORKDIR/fixture-license-cert.yaml" <<'EOF'
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
config:
  extraEnv:
    - name: N8N_LICENSE_CERT
      valueFrom:
        secretKeyRef:
          name: test-license-cert
          key: cert
service:
  type: ClusterIP
  port: 5678
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

echo "==> helm template (license-cert fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace n8n-chart-check \
  -f "$WORKDIR/fixture-license-cert.yaml" \
  >"$WORKDIR/rendered-license-cert.yaml" 2>"$WORKDIR/helm-stderr-license-cert.log"; then
  cat "$WORKDIR/helm-stderr-license-cert.log" >&2
  fail "helm template (license-cert fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the license-cert fixture with no credentials (Helm's JSON-schema validation runs, not skipped)"

  LC_RENDERED="$WORKDIR/rendered-license-cert.yaml"

  # assert_license_cert_env <deployment-name>
  # Confirms exactly one N8N_LICENSE_CERT entry inside the named Deployment's
  # own manifest block (not just somewhere in the combined output), sourced
  # from a secretKeyRef matching n8n_license_cert_secret_ref's
  # name/key (test-license-cert/cert), carrying no literal value, and that
  # the same block renders no N8N_LICENSE_ACTIVATION_KEY.
  assert_license_cert_env() {
    local name="$1" block
    block="$(awk -v name="$name" '
      /^kind: Deployment$/ { in_dep = 1; found_name = 0; buf = ""; next }
      in_dep && $0 == "  name: " name { found_name = 1 }
      in_dep && found_name { buf = buf $0 "\n" }
      /^---$/ { if (found_name) { print buf; exit }; in_dep = 0; found_name = 0; buf = "" }
    ' "$LC_RENDERED")"

    local count
    count="$(echo "$block" | grep -c -- '- name: N8N_LICENSE_CERT$' || true)"
    if [ "$count" != "1" ]; then
      fail "Deployment/${name}: expected exactly 1 N8N_LICENSE_CERT env entry, found ${count}"
      return
    fi

    local entry
    entry="$(echo "$block" | grep -A4 -- '- name: N8N_LICENSE_CERT$')"
    if echo "$entry" | grep -q 'secretKeyRef:' \
      && echo "$entry" | grep -q 'name: test-license-cert' \
      && echo "$entry" | grep -q 'key: cert'; then
      pass "Deployment/${name} renders N8N_LICENSE_CERT via secretKeyRef (test-license-cert/cert)"
    else
      fail "Deployment/${name}: N8N_LICENSE_CERT entry is missing the expected secretKeyRef shape: ${entry}"
    fi

    if echo "$entry" | sed -n '2p' | grep -q 'value:'; then
      fail "Deployment/${name}: N8N_LICENSE_CERT must not carry a literal value"
    fi

    if echo "$block" | grep -q -- '- name: N8N_LICENSE_ACTIVATION_KEY$'; then
      fail "Deployment/${name}: must not render N8N_LICENSE_ACTIVATION_KEY on the offline-certificate path"
    else
      pass "Deployment/${name} renders no N8N_LICENSE_ACTIVATION_KEY on the offline-certificate path"
    fi
  }

  assert_license_cert_env "n8n-main"
  assert_license_cert_env "n8n-worker"
  assert_license_cert_env "n8n-webhook-processor"
fi

# ── Replica ownership with KEDA on (n8n-hosting#201, chart >= 1.13.0) ───────
# The default fixture above never sets `keda`, so its replica assertions only
# prove the no-autoscaler branch. The module runs with keda.enabled=true and
# worker triggers (n8n.tf), and since chart 1.13.0 that makes the chart omit
# the worker Deployment's `replicas` field entirely (KEDA owns it). The
# webhook-processor Deployment must still carry `replicas`: the module keeps
# hpa.webhookProcessor.enabled=false and never sets keda.webhookProcessor, so
# the chart sees no owner there and the external HPA in scaling.tf keeps
# being reset on every apply. Pinning both halves here means a future chart
# bump that changes either behaviour fails this script instead of silently
# changing what `terraform apply` does to live replica counts.
cat >"$WORKDIR/fixture-keda-on.yaml" <<'EOF'
keda:
  enabled: true
  worker:
    minReplicaCount: 2
    maxReplicaCount: 10
    triggers:
      - type: redis
        metadata:
          listName: "bull:jobs:wait"
          listLength: "5"
          address: "synthetic-redis.internal:6379"
          enableTLS: "false"
EOF

echo "==> helm template (keda-on fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "$CHART_VERSION" \
  --namespace n8n \
  -f "$WORKDIR/fixture-values.yaml" \
  -f "$WORKDIR/fixture-keda-on.yaml" \
  >"$WORKDIR/rendered-keda-on.yaml" 2>"$WORKDIR/helm-stderr-keda-on.log"; then
  fail "helm template (keda-on fixture) failed: $(cat "$WORKDIR/helm-stderr-keda-on.log")"
else
  KEDA_WORKER_REPLICAS="$(awk '
    /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
    in_deploy && $0 == "  name: n8n-worker" { found_name = 1; next }
    in_deploy && found_name && /^  replicas:/ { print $2; exit }
    /^---$/ { in_deploy = 0; found_name = 0 }
  ' "$WORKDIR/rendered-keda-on.yaml")"
  if [ -z "$KEDA_WORKER_REPLICAS" ]; then
    pass "keda-on: Deployment/n8n-worker renders no replicas field (KEDA owns the count)"
  else
    fail "keda-on: Deployment/n8n-worker still renders replicas: ${KEDA_WORKER_REPLICAS}; chart no longer defers the worker count to KEDA"
  fi

  KEDA_WEBHOOK_REPLICAS="$(awk '
    /^kind: Deployment$/ { in_deploy = 1; found_name = 0; next }
    in_deploy && $0 == "  name: n8n-webhook-processor" { found_name = 1; next }
    in_deploy && found_name && /^  replicas:/ { print $2; exit }
    /^---$/ { in_deploy = 0; found_name = 0 }
  ' "$WORKDIR/rendered-keda-on.yaml")"
  if [ "$KEDA_WEBHOOK_REPLICAS" = "1" ]; then
    pass "keda-on: Deployment/n8n-webhook-processor still renders replicas: 1 (no chart-side owner; external HPA resets it each apply)"
  else
    fail "keda-on: Deployment/n8n-webhook-processor replicas: expected 1, got '${KEDA_WEBHOOK_REPLICAS:-<not found>}'; the chart's webhook ownership rule changed, re-check scaling.tf's external HPA"
  fi

  if grep -q '^kind: ScaledObject$' "$WORKDIR/rendered-keda-on.yaml"; then
    pass "keda-on: a ScaledObject is rendered for the worker"
  else
    fail "keda-on: no ScaledObject rendered despite keda.enabled=true with worker triggers"
  fi
fi

# ── Graceful shutdown timeout (redis.worker.timeout) ────────────────────────
# local.n8n_queue_worker_chart_overrides (locals.tf) merges timeout into the
# chart's redis.worker map only when n8n_graceful_shutdown_timeout is set
# (n8n.tf); helm_release.values is unknown at plan time under the mock
# provider, so tftest.hcl asserts only the local's shape. This renders the
# real chart's configmap.yaml to prove an override actually reaches the
# N8N_GRACEFUL_SHUTDOWN_TIMEOUT key, and that omitting it still resolves to
# the chart's own default. That default is compared against
# local.n8n_chart_default_graceful_shutdown_timeout (read straight from
# locals.tf, since this script runs no Terraform), which the
# graceful_shutdown_fits_grace_period check relies on, so a chart bump that
# moves the default fails here until that local is updated.
EXPECTED_DEFAULT_SHUTDOWN_TIMEOUT="$(sed -nE 's/^[[:space:]]*n8n_chart_default_graceful_shutdown_timeout[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' locals.tf)"
if [[ -z "$EXPECTED_DEFAULT_SHUTDOWN_TIMEOUT" ]]; then
  fail "could not read local.n8n_chart_default_graceful_shutdown_timeout from locals.tf"
  EXPECTED_DEFAULT_SHUTDOWN_TIMEOUT="<unreadable>"
fi
cat >"$WORKDIR/fixture-graceful-shutdown-default.yaml" <<'EOF'
redis:
  worker: {}
EOF
cat >"$WORKDIR/fixture-graceful-shutdown-overridden.yaml" <<'EOF'
redis:
  worker:
    timeout: 45
EOF
for scenario in default overridden; do
  if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
    --version "${CHART_VERSION}" \
    -f "$WORKDIR/fixture-values.yaml" \
    -f "$WORKDIR/fixture-graceful-shutdown-$scenario.yaml" \
    --show-only templates/configmap.yaml \
    >"$WORKDIR/configmap-$scenario.yaml" 2>"$WORKDIR/helm-graceful-shutdown-$scenario.err"; then
    fail "helm template (graceful-shutdown-$scenario fixture) failed: $(cat "$WORKDIR/helm-graceful-shutdown-$scenario.err")"
  fi
done
if grep -qF "N8N_GRACEFUL_SHUTDOWN_TIMEOUT: \"${EXPECTED_DEFAULT_SHUTDOWN_TIMEOUT}\"" "$WORKDIR/configmap-default.yaml"; then
  pass "graceful shutdown timeout omitted resolves to the chart's own default (${EXPECTED_DEFAULT_SHUTDOWN_TIMEOUT}s, matching locals.tf)"
else
  fail "graceful shutdown timeout omitted did not resolve to local.n8n_chart_default_graceful_shutdown_timeout (${EXPECTED_DEFAULT_SHUTDOWN_TIMEOUT}s); update that local to the chart's new default"
fi
if grep -q 'N8N_GRACEFUL_SHUTDOWN_TIMEOUT: "45"' "$WORKDIR/configmap-overridden.yaml"; then
  pass "n8n_graceful_shutdown_timeout override reaches N8N_GRACEFUL_SHUTDOWN_TIMEOUT in the ConfigMap"
else
  fail "n8n_graceful_shutdown_timeout override did not reach N8N_GRACEFUL_SHUTDOWN_TIMEOUT in the ConfigMap"
fi

# ── Worker KEDA pause annotations (n8n_worker_keda_pause, chart #177) ───────
# The keda-on render above leaves pause at its default: the worker
# ScaledObject must carry neither pause annotation. A second render with
# pause=true and pausedReplicaCount=0 (the scale-to-zero case; 0 is falsy in
# Go templates, which the chart guards against by kind) must carry both.
scaledobject_annotation() {
  # scaledobject_annotation <rendered-file> <annotation-key>
  awk -v key="$2" '
    /^kind: ScaledObject$/ { in_so = 1; next }
    in_so && $0 == "  name: n8n-worker" { found = 1; next }
    in_so && found && $1 == key ":" { print $2; exit }
    /^---$/ { in_so = 0; found = 0 }
  ' "$1"
}
if [ -n "$(scaledobject_annotation "$WORKDIR/rendered-keda-on.yaml" "autoscaling.keda.sh/paused")" ]; then
  fail "keda-on default: worker ScaledObject carries autoscaling.keda.sh/paused although keda.worker.pause is unset"
else
  pass "keda-on default: worker ScaledObject has no pause annotation"
fi

cat >"$WORKDIR/fixture-keda-paused.yaml" <<'EOF'
keda:
  worker:
    pause: true
    pausedReplicaCount: 0
EOF
echo "==> helm template (keda paused fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "$CHART_VERSION" \
  --namespace n8n \
  -f "$WORKDIR/fixture-values.yaml" \
  -f "$WORKDIR/fixture-keda-on.yaml" \
  -f "$WORKDIR/fixture-keda-paused.yaml" \
  >"$WORKDIR/rendered-keda-paused.yaml" 2>"$WORKDIR/helm-stderr-keda-paused.log"; then
  fail "helm template (keda paused fixture) failed: $(cat "$WORKDIR/helm-stderr-keda-paused.log")"
else
  PAUSED="$(scaledobject_annotation "$WORKDIR/rendered-keda-paused.yaml" "autoscaling.keda.sh/paused")"
  PAUSED_REPLICAS="$(scaledobject_annotation "$WORKDIR/rendered-keda-paused.yaml" "autoscaling.keda.sh/paused-replicas")"
  if [ "$PAUSED" = '"true"' ]; then
    pass "keda paused: worker ScaledObject carries autoscaling.keda.sh/paused: \"true\""
  else
    fail "keda paused: autoscaling.keda.sh/paused expected \"true\", got '${PAUSED:-<not found>}'"
  fi
  if [ "$PAUSED_REPLICAS" = '"0"' ]; then
    pass "keda paused: worker ScaledObject carries autoscaling.keda.sh/paused-replicas: \"0\" (scale-to-zero hold survives Go's falsy zero)"
  else
    fail "keda paused: autoscaling.keda.sh/paused-replicas expected \"0\", got '${PAUSED_REPLICAS:-<not found>}'"
  fi
fi

# ── Task-runner sidecar placement (n8n-hosting#179, chart >= 1.13.0) ────────
# In queue mode (always, here) the chart renders the task-runner sidecar on
# worker pods only; main offloads manual executions to workers and starts no
# runner broker. capacity.tf's node-capacity model relies on this (main
# ceiling carries no sidecar term), so pin it against the default render.
deployment_has_container() {
  # deployment_has_container <rendered-file> <deployment-name> <container-name>
  awk -v dep="$2" -v ctr="$3" '
    /^kind: Deployment$/ { in_dep = 1; found = 0; next }
    in_dep && $0 == "  name: " dep { found = 1; next }
    in_dep && found && $0 == "        - name: " ctr { print "yes"; exit }
    /^---$/ { in_dep = 0; found = 0 }
  ' "$1"
}
cat >"$WORKDIR/fixture-task-runners.yaml" <<'EOF'
taskRunners:
  enabled: true
EOF
echo "==> helm template (task-runners fixture) ${CHART_REPOSITORY}/${CHART_NAME} --version ${CHART_VERSION}"
if ! helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" \
  --version "$CHART_VERSION" \
  --namespace n8n \
  -f "$WORKDIR/fixture-values.yaml" \
  -f "$WORKDIR/fixture-task-runners.yaml" \
  >"$WORKDIR/rendered-task-runners.yaml" 2>"$WORKDIR/helm-stderr-task-runners.log"; then
  fail "helm template (task-runners fixture) failed: $(cat "$WORKDIR/helm-stderr-task-runners.log")"
else
  if [ "$(deployment_has_container "$WORKDIR/rendered-task-runners.yaml" "n8n-worker" "task-runner")" = "yes" ]; then
    pass "task runners: Deployment/n8n-worker carries the task-runner sidecar"
  else
    fail "task runners: Deployment/n8n-worker has no task-runner sidecar with taskRunners.enabled=true"
  fi
  if [ -n "$(deployment_has_container "$WORKDIR/rendered-task-runners.yaml" "n8n-main" "task-runner")" ]; then
    fail "task runners: Deployment/n8n-main renders a task-runner sidecar in queue mode; capacity.tf's main ceiling assumes none (chart #179)"
  else
    pass "task runners: Deployment/n8n-main renders no task-runner sidecar in queue mode (chart #179)"
  fi
  if [ -n "$(deployment_has_container "$WORKDIR/rendered-task-runners.yaml" "n8n-webhook-processor" "task-runner")" ]; then
    fail "task runners: Deployment/n8n-webhook-processor renders a task-runner sidecar"
  else
    pass "task runners: Deployment/n8n-webhook-processor renders no task-runner sidecar"
  fi
fi

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
