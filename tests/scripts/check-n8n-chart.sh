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
# A second render with the exact fragments locals.tf computes for single-main
# (n8n_single_main=true): multiMain.enabled=false, top-level replicaCount=1,
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
    availableModes: "filesystem,s3"
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
fi

# ── Return to multi-main (task 3.3) ─────────────────────────────────────────
# Confirms the main Deployment's/PDB's rendering reverts once multiMain is
# re-enabled with a count above one, proving topology is not sticky: this is
# the exact fixture-values.yaml fixture above (replicas: 2), so reuse
# $RENDERED rather than rendering a third time.
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
    availableModes: "filesystem,s3"
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
# local.effective_webhook_url and https://<n8n_fqdn> respectively), using
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
    availableModes: "filesystem,s3"
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
    availableModes: "filesystem,s3"
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
