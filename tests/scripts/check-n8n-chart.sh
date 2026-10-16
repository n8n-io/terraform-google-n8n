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
# Chart 2.0 is the unreleased n8n-hosting `main` line (past the latest tag,
# v1.16.0). It replaced the nine `extraEnv`/`extraEnvFrom` lists with one
# flat `env.<component>` map per component (n8n-io/n8n-hosting#250),
# rendered into per-component ConfigMaps that every container loads with
# `envFrom`. Only `env`/`chartEnvOverrides` references (a value with
# `secretKeyRef`/`configMapKeyRef`/etc.) and the chart's own Secret-sourced
# variables (encryption key, DB password, ...) still appear as explicit
# `env:` list entries. See UPGRADING.md and decisions/0012 in the chart repo.
#
# What this checks, matching task 1.3 (re-expressed against the 2.0 render):
#   - The pinned chart renders cleanly with no credentials.
#   - Floor seeding: multiMain.replicas / queueMode.workerReplicaCount /
#     webhookProcessor.replicaCount reach the main/worker/webhook-processor
#     Deployments' `replicas` field unmodified.
#   - service.annotations (the BackendConfig annotation the module sets when
#     create_ingress = true) reaches BOTH the main and the webhook-processor
#     Service, not just the main one.
#   - executions.data reaches the four EXECUTIONS_DATA_SAVE_* keys in the
#     main and worker env ConfigMaps (the chart renders no executions keys
#     into the webhook-processor ConfigMap), for both the default
#     all/all/false/true policy and a mixed non-default policy.
#   - database.ssl with a PostgreSQL CA renders DB_POSTGRESDB_SSL_CA into the
#     shared env ConfigMap and reaches every role through envFrom, with no
#     DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED of the chart's own (rejected
#     unauthorized stays the default), and a changed CA changes each role's
#     checksum/config annotation (so a CA change rolls the pods).
#   - The nine retired extraEnv/extraEnvFrom lists, the retired
#     secretRefs.env.N8N_HOST/N8N_PORT/N8N_PROTOCOL keys, webhook.timeout,
#     and the queueMode.workerConcurrency + executions.concurrency.
#     productionLimit conflict all fail the render with the documented
#     replacement named, so the module cannot accidentally ship a 1.x-shaped
#     value that the chart would now silently ignore (decision 0020).
#   - Image pull Secrets (n8n-io/n8n-hosting#180) render natively on every
#     n8n pod via the top-level imagePullSecrets value, and the chart's own
#     ServiceAccount keeps its Workload Identity annotation; the module
#     takes over no ServiceAccount from the chart.
#   - The self-check below proves an intentionally wrong expected value is
#     actually caught (a real assertion failure), not a check that always
#     passes.
#
# Usage: tests/scripts/check-n8n-chart.sh
#   N8N_CHART_DIR=/path/to/n8n-hosting/charts/n8n tests/scripts/check-n8n-chart.sh
#     renders that local chart checkout instead of pulling
#     CHART_REPOSITORY/CHART_NAME:CHART_VERSION from the OCI registry. Chart
#     2.0 is unreleased at the time this script targets it (the current
#     state of n8n-hosting `main`, past the latest tag); point this at a
#     local clone of that branch during development. The CHART_VERSION ==
#     variables.tf guard below still runs either way; only the chart
#     *source* changes.
# Requires: helm (any version able to pull OCI charts) and python3 (used by
# tests/scripts/lib/tf-defaults.sh to read the module's chart pins).

set -euo pipefail

cd "$(dirname "$0")/../.."

CHART_REPOSITORY="oci://ghcr.io/n8n-io/n8n-helm-chart"
CHART_NAME="n8n"
CHART_VERSION="2.0.0"

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

# render_chart <out-file> <err-file> <namespace> [helm template args...]
# Renders release "n8n" either from N8N_CHART_DIR (a local chart checkout) or
# from the pinned CHART_REPOSITORY/CHART_NAME:CHART_VERSION, depending on
# whether N8N_CHART_DIR is set. Bash-3.2-safe: branches on the whole command
# instead of building a possibly-empty array of `--version` args (an empty
# array expansion under `set -u` is unsafe on bash < 4.4).
if [ -n "${N8N_CHART_DIR:-}" ]; then
  echo "NOTICE: N8N_CHART_DIR=${N8N_CHART_DIR} is set; every render below uses that local chart checkout instead of pulling ${CHART_REPOSITORY}/${CHART_NAME}:${CHART_VERSION} from the registry. The pinned-registry pull is bypassed; unset N8N_CHART_DIR to verify against the real pinned chart." >&2
  CHART_DISPLAY="${N8N_CHART_DIR} (local)"
else
  CHART_DISPLAY="${CHART_REPOSITORY}/${CHART_NAME}:${CHART_VERSION}"
fi
render_chart() {
  local out="$1" err="$2" ns="$3"
  shift 3
  if [ -n "${N8N_CHART_DIR:-}" ]; then
    helm template n8n "$N8N_CHART_DIR" --namespace "$ns" "$@" >"$out" 2>"$err"
  else
    helm template n8n "${CHART_REPOSITORY}/${CHART_NAME}" --version "${CHART_VERSION}" --namespace "$ns" "$@" >"$out" 2>"$err"
  fi
}

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

# manifest_block <file> <kind> <name>
# Prints just the one rendered object matching `kind: <kind>` / a
# `  name: <name>` line in its own manifest block, so every assertion below
# is per-object: a role with a missing entry cannot be hidden by a duplicate
# on another role. Each rendered document is delimited by helm's own `---`.
manifest_block() {
  awk -v kind="kind: $2" -v name="  name: $3" '
    /^---$/ { if (found) exit; in_kind = 0; found = 0; next }
    $0 == kind { in_kind = 1 }
    in_kind && $0 == name { found = 1 }
    found { print }
  ' "$1"
}

# assert_deployment_replicas <file> <deployment-name> <expected-replica-count>
assert_deployment_replicas() {
  local file="$1" name="$2" expected="$3" actual
  actual="$(manifest_block "$file" Deployment "$name" | sed -nE 's/^  replicas: (.*)$/\1/p' | head -1)"
  if [ "$actual" = "$expected" ]; then
    pass "Deployment/${name} replicas == ${expected}"
  else
    fail "Deployment/${name} replicas: expected ${expected}, got '${actual:-<not found>}'"
  fi
}

# assert_service_annotation <file> <service-name> <annotation-key> <expected-value>
assert_service_annotation() {
  local file="$1" name="$2" key="$3" expected="$4" block
  block="$(manifest_block "$file" Service "$name")"
  if echo "$block" | grep -qF "${key}: '${expected}'" || echo "$block" | grep -qF "${key}: \"${expected}\""; then
    pass "Service/${name} carries annotation ${key}"
  else
    fail "Service/${name} is missing annotation ${key}=${expected}"
  fi
}

# assert_configmap_value <file> <configmap-name> <key> <expected-value>
# Checks a single-line ConfigMap data entry, quoted or bare.
assert_configmap_value() {
  local file="$1" cmname="$2" key="$3" expected="$4" block
  block="$(manifest_block "$file" ConfigMap "$cmname")"
  if echo "$block" | grep -qxF "  ${key}: ${expected}" || echo "$block" | grep -qxF "  ${key}: \"${expected}\""; then
    pass "ConfigMap/${cmname} ${key} == ${expected}"
  else
    fail "ConfigMap/${cmname} ${key}: expected ${expected}, not found"
  fi
}

# assert_configmap_key_absent <file> <configmap-name> <key>
assert_configmap_key_absent() {
  local file="$1" cmname="$2" key="$3" block
  block="$(manifest_block "$file" ConfigMap "$cmname")"
  if echo "$block" | grep -q "^  ${key}:"; then
    fail "ConfigMap/${cmname} unexpectedly renders ${key}"
  else
    pass "ConfigMap/${cmname} renders no ${key}"
  fi
}

# assert_envfrom_ref <file> <deployment-name> <configmap-name>
# Confirms the Deployment's envFrom list references the named ConfigMap
# exactly once. envFrom.configMapRef.name lines render 16 spaces deep
# (containers -> envFrom -> - configMapRef -> name), which distinguishes them
# from the 2-space metadata `name:` and the unrelated `app.kubernetes.io/
# name:` label keys that also contain the substring "name:".
assert_envfrom_ref() {
  local file="$1" deployment="$2" cmname="$3" actual
  actual="$(manifest_block "$file" Deployment "$deployment" | grep -c -- "^                name: ${cmname}\$" || true)"
  if [ "$actual" = "1" ]; then
    pass "Deployment/${deployment} envFrom references ConfigMap/${cmname}"
  else
    fail "Deployment/${deployment} envFrom: expected exactly 1 reference to ConfigMap/${cmname}, found ${actual}"
  fi
}

# ── Synthetic values fixture ─────────────────────────────────────────────────
# Deliberately distinct, non-default numbers (2 / 3 / 1) for the three replica
# fields so a check that silently compares the chart's own defaults against
# themselves cannot pass by accident. Coordinates (hosts, secret names) are
# synthetic placeholders; no resource in this repo is asked to exist.
# This mirrors the input-derived fragments this change shares as locals
# (locals.tf's "n8n Helm chart value fragments"), not the full Helm values
# blob helm_release.n8n builds (which also carries resource-derived Secret
# coordinates that only resolve during a real apply). queueMode.
# workerConcurrency is deliberately absent: chart 2.0 defaults it to empty,
# and the module's 2.0 default follows upstream guidance to keep
# executions.concurrency.productionLimit instead (see the retired-keys /
# conflict section below).
cat >"$WORKDIR/fixture-values.yaml" <<'EOF'
multiMain:
  enabled: true
  replicas: 2
queueMode:
  enabled: true
  workerReplicaCount: 3
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

echo "==> helm template ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered.yaml" "$WORKDIR/helm-stderr.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml"; then
  cat "$WORKDIR/helm-stderr.log" >&2
  fail "helm template exited non-zero; see stderr above. This chart version/repository may no longer exist, need credentials it did not get, or reject the fixture values."
  echo "Failures: $FAILURES" >&2
  exit 1
fi
pass "helm template rendered ${CHART_NAME}:${CHART_VERSION} with no credentials"

RENDERED="$WORKDIR/rendered.yaml"

assert_deployment_replicas "$RENDERED" "n8n-main" "2"
assert_deployment_replicas "$RENDERED" "n8n-webhook-processor" "1"
assert_deployment_replicas "$RENDERED" "n8n-worker" "3"

assert_service_annotation "$RENDERED" "n8n-main" "cloud.google.com/backend-config" '{"default":"n8n-backendconfig"}'
assert_service_annotation "$RENDERED" "n8n-webhook-processor" "cloud.google.com/backend-config" '{"default":"n8n-backendconfig"}'

# EXECUTIONS_DATA_SAVE_* now lands in the main and worker env ConfigMaps
# (n8n-main / n8n-worker), loaded by their respective Deployments via
# envFrom; the chart renders no executions keys into the webhook-processor
# ConfigMap at all (confirmed below by their absence).
for role_cm in n8n-main n8n-worker; do
  assert_configmap_value "$RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_ON_ERROR" "all"
  assert_configmap_value "$RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_ON_SUCCESS" "all"
  assert_configmap_value "$RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_ON_PROGRESS" '"false"'
  assert_configmap_value "$RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS" '"true"'
done
assert_configmap_key_absent "$RENDERED" "n8n-webhook-processor" "EXECUTIONS_DATA_SAVE_ON_ERROR"

# Every n8n-rendering Deployment loads the shared ConfigMap ("n8n") plus its
# own component ConfigMap via envFrom; this is a chart-structural constant
# (templates/_env.tpl's containerEnv), asserted once here so later sections
# can rely on it instead of re-proving it per fixture.
assert_envfrom_ref "$RENDERED" "n8n-main" "n8n"
assert_envfrom_ref "$RENDERED" "n8n-main" "n8n-main"
assert_envfrom_ref "$RENDERED" "n8n-worker" "n8n"
assert_envfrom_ref "$RENDERED" "n8n-worker" "n8n-worker"
assert_envfrom_ref "$RENDERED" "n8n-webhook-processor" "n8n"
assert_envfrom_ref "$RENDERED" "n8n-webhook-processor" "n8n-webhook-processor"

# n8n deprecated N8N_AVAILABLE_BINARY_DATA_MODES and logs a warning whenever
# it is set, even though n8n 2.x otherwise ignores it. The chart has no
# template path that renders it (grepped templates/_env.tpl) and the module
# never sends s3.storage.availableModes (n8n.tf). N8N_DEFAULT_BINARY_DATA_MODE
# must have rendered first, or the absence check would pass vacuously.
assert_configmap_value "$RENDERED" "n8n" "N8N_DEFAULT_BINARY_DATA_MODE" "s3"
assert_configmap_key_absent "$RENDERED" "n8n" "N8N_AVAILABLE_BINARY_DATA_MODES"

# The legacy WEBHOOK_URL variable has no chart-native key in 2.0 at all (the
# chart only knows editor.url/webhook.url -> N8N_EDITOR_BASE_URL/
# N8N_WEBHOOK_URL); a module that wants it for images predating n8n 2.30.0
# sets it as a plain env.shared literal (see the public-urls fixture below).
# This default fixture sets neither, so it must be absent here.
assert_configmap_key_absent "$RENDERED" "n8n" "WEBHOOK_URL"

# ── Mixed execution-save policy (task 6.1) ──────────────────────────────────
# A second render of the same fixture with a non-default, non-uniform
# executions.data policy, proving the chart renders each of the four values
# independently rather than only ever exercising the all/all/false/true
# default combination above. Webhook-processor is deliberately excluded: the
# chart's executions keys only render into the main/worker ConfigMaps.
sed 's/^\([[:space:]]*saveOnError: \).*/\1none/; s/^\([[:space:]]*saveOnProgress: \).*/\1true/; s/^\([[:space:]]*saveManualExecutions: \).*/\1false/' \
  "$WORKDIR/fixture-values.yaml" >"$WORKDIR/fixture-mixed-executions.yaml"

echo "==> helm template (mixed execution-save fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-mixed-executions.yaml" "$WORKDIR/helm-stderr-mixed-executions.log" n8n-chart-check -f "$WORKDIR/fixture-mixed-executions.yaml"; then
  cat "$WORKDIR/helm-stderr-mixed-executions.log" >&2
  fail "helm template (mixed execution-save fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the mixed execution-save fixture with no credentials"
  MIXED_RENDERED="$WORKDIR/rendered-mixed-executions.yaml"
  for role_cm in n8n-main n8n-worker; do
    assert_configmap_value "$MIXED_RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_ON_ERROR" "none"
    assert_configmap_value "$MIXED_RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_ON_SUCCESS" "all"
    assert_configmap_value "$MIXED_RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_ON_PROGRESS" '"true"'
    assert_configmap_value "$MIXED_RENDERED" "$role_cm" "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS" '"false"'
  done
  assert_configmap_key_absent "$MIXED_RENDERED" "n8n-webhook-processor" "EXECUTIONS_DATA_SAVE_ON_ERROR"
fi

# ── Retired 1.x values keys fail the render (decision 0020) ────────────────
# Chart 2.0 fails the render, naming the replacement, for every values key it
# no longer reads (UPGRADING.md). Proves the module cannot accidentally ship
# a 1.x-shaped value that the chart would otherwise silently ignore. One
# render per key, each asserted independently so a message regression on one
# key cannot hide behind a passing render of another.
assert_render_fails_with() {
  # assert_render_fails_with <fixture-file> <expected-message-substring> <description>
  local fixture="$1" expected="$2" description="$3" out
  out="$WORKDIR/retired-$(basename "$fixture" .yaml).log"
  if render_chart "$WORKDIR/retired-$(basename "$fixture" .yaml).yaml" "$out" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$fixture" >/dev/null 2>&1; then
    fail "${description}: helm template unexpectedly succeeded; chart 2.0 should reject this 1.x-shaped value"
  elif grep -qF "$expected" "$out"; then
    pass "${description}: render fails with the documented replacement named"
  else
    fail "${description}: render failed, but not with the expected message (got: $(cat "$out"))"
  fi
}

cat >"$WORKDIR/fixture-retired-extraenv.yaml" <<'EOF'
config:
  extraEnv:
    - name: N8N_LOG_LEVEL
      value: debug
EOF
assert_render_fails_with "$WORKDIR/fixture-retired-extraenv.yaml" \
  "config.extraEnv is no longer read. Set these variables in env.shared" \
  "config.extraEnv"

cat >"$WORKDIR/fixture-retired-host.yaml" <<'EOF'
secretRefs:
  env:
    N8N_HOST: n8n.example.test
EOF
assert_render_fails_with "$WORKDIR/fixture-retired-host.yaml" \
  "secretRefs.env.N8N_HOST is no longer read" \
  "secretRefs.env.N8N_HOST"

cat >"$WORKDIR/fixture-retired-timeout.yaml" <<'EOF'
webhook:
  timeout: 120
EOF
assert_render_fails_with "$WORKDIR/fixture-retired-timeout.yaml" \
  "webhook.timeout has no effect" \
  "webhook.timeout"

# queueMode.workerConcurrency and executions.concurrency.productionLimit both
# set each worker's concurrency in queue mode; n8n uses productionLimit and
# ignores the --concurrency flag, so the chart fails rather than silently
# picking one.
cat >"$WORKDIR/fixture-concurrency-conflict.yaml" <<'EOF'
queueMode:
  workerConcurrency: 5
executions:
  concurrency:
    productionLimit: 10
EOF
assert_render_fails_with "$WORKDIR/fixture-concurrency-conflict.yaml" \
  "queueMode.workerConcurrency and executions.concurrency.productionLimit both set" \
  "queueMode.workerConcurrency + executions.concurrency.productionLimit conflict"

# ── Single-main topology (task 3.1/3.3) ─────────────────────────────────────
# A second render with the default fragments locals.tf computes for single-main
# (n8n_single_main=true, election override null): multiMain.enabled=false,
# replicaCount=1, strategy={type: Recreate}. The module sets no pdb value at
# all (decision 0004: the chart gates its own main PodDisruptionBudget on
# effective main replica count / hpa.main.minReplicas); this fixture's
# hpa.main.minReplicas=1 exercises the chart's own no-PDB-at-one-replica path.
# Proves the chart actually turns these fragments into a Recreate main
# Deployment with no PodDisruptionBudget, and leaves worker/webhook replicas
# and strategy untouched.
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

echo "==> helm template (single-main fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-single-main.yaml" "$WORKDIR/helm-stderr-single-main.log" n8n-chart-check -f "$WORKDIR/fixture-single-main.yaml"; then
  cat "$WORKDIR/helm-stderr-single-main.log" >&2
  fail "helm template (single-main fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the single-main fixture with no credentials"

  SM_RENDERED="$WORKDIR/rendered-single-main.yaml"

  # assert_deployment_strategy <file> <deployment-name> <expected-type-or-empty>
  # An expected value of "" asserts the Deployment has NO strategy block at
  # all (the chart's `with .Values.strategy` guard omits the whole key).
  assert_deployment_strategy() {
    local file="$1" name="$2" expected="$3" actual
    actual="$(manifest_block "$file" Deployment "$name" | awk '
      /^  strategy:/ { in_strategy = 1; next }
      in_strategy && /^    type:/ { print $2; exit }
      /^  selector:/ { exit }
    ')"
    if [ "$actual" = "$expected" ]; then
      pass "Deployment/${name} strategy.type == '${expected:-<absent>}'"
    else
      fail "Deployment/${name} strategy.type: expected '${expected:-<absent>}', got '${actual:-<absent>}'"
    fi
  }

  # assert_pdb_absent <file>
  # decisions/0004-pdb-needs-a-second-main-pod.md: templates/pdb.yaml
  # intentionally renders the main PodDisruptionBudget only when main can
  # run more than one pod (effective replicas > 1, or hpa.main enabled with
  # minReplicas > 1). At one main replica with hpa.main.minReplicas=1 (this
  # fixture's single-main/election-staging shape) the chart renders no
  # PodDisruptionBudget at all, so a node drain can evict the sole main
  # pod without the module setting anything; this is the intended
  # chart-native replacement for the module's old pdb.minAvailable=0 value.
  assert_pdb_absent() {
    local file="$1"
    if grep -q '^kind: PodDisruptionBudget$' "$file"; then
      fail "PodDisruptionBudget: expected none (main replicas/hpa min both 1), found one"
    else
      pass "no PodDisruptionBudget rendered (main replicas/hpa min both 1; chart-native drain-friendly single-main, decision 0004)"
    fi
  }

  assert_deployment_replicas "$SM_RENDERED" "n8n-main" "1"
  assert_deployment_strategy "$SM_RENDERED" "n8n-main" "Recreate"
  assert_deployment_strategy "$SM_RENDERED" "n8n-worker" ""
  assert_deployment_strategy "$SM_RENDERED" "n8n-webhook-processor" ""
  assert_pdb_absent "$SM_RENDERED"

  # No disabled scalers: worker/webhook queue-mode Deployments still render
  # at their configured replica counts; single-main only changes the main
  # rollout/PDB/HPA ceiling, not whether workers or webhook processors exist.
  assert_deployment_replicas "$SM_RENDERED" "n8n-worker" "3"

  # Chart 2.0 only sets N8N_MULTI_MAIN_SETUP_ENABLED when
  # multiMain.enabled && license.enabled (templates/_env.tpl's chartEnv), so
  # with multiMain disabled here the chart sets nothing: a literal in
  # env.shared cannot collide with it, unlike 1.x's config.extraEnv/
  # configMapKeyRef election workaround.
  assert_configmap_key_absent "$SM_RENDERED" "n8n-main" "N8N_MULTI_MAIN_SETUP_ENABLED"

  # Stage one changes election only, retaining the one-replica safeguards.
  # This is a render assertion, not proof of upgrade ordering or runtime
  # safety. env.shared reaches main, worker and webhook-processor alike
  # through the one shared ConfigMap ("n8n"), so a single literal there
  # (rather than three separate 1.x extraEnv entries) is enough to stage the
  # flag on all three roles at once.
  cat >"$WORKDIR/fixture-election-staging.yaml" <<'EOF'
env:
  shared:
    N8N_MULTI_MAIN_SETUP_ENABLED: "true"
EOF
  if ! render_chart "$WORKDIR/rendered-election-staging.yaml" "$WORKDIR/helm-stderr-election-staging.log" n8n-chart-check -f "$WORKDIR/fixture-single-main.yaml" -f "$WORKDIR/fixture-election-staging.yaml" --set keda.enabled=true; then
    cat "$WORKDIR/helm-stderr-election-staging.log" >&2
    fail "helm template (election staging) exited non-zero"
  else
    ES_RENDERED="$WORKDIR/rendered-election-staging.yaml"
    assert_deployment_replicas "$ES_RENDERED" "n8n-main" "1"
    # keda.enabled=true with the chart's default worker triggers makes the
    # chart (>= 1.13.0, n8n-hosting#201) omit the worker Deployment's
    # `replicas` and leave the count to the ScaledObject; the webhook
    # processor below has no chart-side owner here and keeps its count.
    ES_WORKER_REPLICAS="$(manifest_block "$ES_RENDERED" Deployment n8n-worker | sed -nE 's/^  replicas: (.*)$/\1/p' | head -1)"
    if [ -z "$ES_WORKER_REPLICAS" ]; then
      pass "election staging (keda on): Deployment/n8n-worker renders no replicas field (KEDA owns the count)"
    else
      fail "election staging (keda on): Deployment/n8n-worker still renders replicas: ${ES_WORKER_REPLICAS}"
    fi
    assert_deployment_replicas "$ES_RENDERED" "n8n-webhook-processor" "1"
    assert_deployment_strategy "$ES_RENDERED" "n8n-main" "Recreate"
    assert_deployment_strategy "$ES_RENDERED" "n8n-worker" ""
    assert_deployment_strategy "$ES_RENDERED" "n8n-webhook-processor" ""
    assert_pdb_absent "$ES_RENDERED"

    ES_HPA="$(awk '
      /^kind: HorizontalPodAutoscaler$/ { in_hpa = 1; next }
      in_hpa && /^  name: n8n-main$/ { main = 1 }
      in_hpa && main && /^  (minReplicas|maxReplicas):/ { print $1, $2 }
      /^---$/ { in_hpa = 0; main = 0 }
    ' "$ES_RENDERED")"
    if [ "$(printf '%s\n' "$ES_HPA" | sort)" = "$(printf 'maxReplicas: 1\nminReplicas: 1')" ]; then
      pass "election staging main HPA min/max == 1/1"
    else
      fail "election staging main HPA must have min/max 1/1: $ES_HPA"
    fi

    # The literal lands in the shared ConfigMap ("n8n") exactly once, and
    # chart multiMain stays disabled (no per-role duplicate in n8n-main).
    assert_configmap_value "$ES_RENDERED" "n8n" "N8N_MULTI_MAIN_SETUP_ENABLED" '"true"'
    assert_configmap_key_absent "$ES_RENDERED" "n8n-main" "N8N_MULTI_MAIN_SETUP_ENABLED"
    assert_envfrom_ref "$ES_RENDERED" "n8n-main" "n8n"
    assert_envfrom_ref "$ES_RENDERED" "n8n-worker" "n8n"
    assert_envfrom_ref "$ES_RENDERED" "n8n-webhook-processor" "n8n"
  fi
fi

# ── Return to multi-main (task 3.3) ─────────────────────────────────────────
# With multiMain.enabled && license.enabled (the default fixture's shape),
# the chart sets its own N8N_MULTI_MAIN_SETUP_ENABLED in the main
# ConfigMap - no module action needed, unlike 1.x's explicit
# config.extraEnv/configMapKeyRef election reference. Reusing the
# independent default render does NOT test an upgrade or prove that the old
# ReplicaSet was replaced before scaling.
assert_configmap_value "$RENDERED" "n8n-main" "N8N_MULTI_MAIN_SETUP_ENABLED" '"true"'

assert_deployment_strategy_absent_in_default() {
  local actual
  actual="$(manifest_block "$RENDERED" Deployment n8n-main | awk '
    /^  strategy:/ { in_strategy = 1; next }
    in_strategy && /^    type:/ { print $2; exit }
    /^  selector:/ { exit }
  ')"
  if [ -z "$actual" ]; then
    pass "default (multi-main) Deployment/n8n-main has no strategy override (chart default applies)"
  else
    fail "default (multi-main) Deployment/n8n-main unexpectedly has strategy.type=${actual}"
  fi
}
assert_deployment_strategy_absent_in_default

# decisions/0004-pdb-needs-a-second-main-pod.md: with the module's default
# multi-main shape (effective main replicas = 2 > 1), the chart renders
# exactly one main PodDisruptionBudget at its own default minAvailable: 1
# (the module sets no pdb value at all; see helm-chart-coverage.md's pdb row).
assert_pdb_min_available() {
  local file="$1" name="$2" expected="$3" count actual
  count="$(grep -c '^kind: PodDisruptionBudget$' "$file" || true)"
  if [ "$count" != "1" ]; then
    fail "PodDisruptionBudget: expected exactly 1 rendered, found ${count}"
    return
  fi
  actual="$(manifest_block "$file" PodDisruptionBudget "$name" | sed -nE 's/^  minAvailable: (.*)$/\1/p' | head -1)"
  if [ "$actual" = "$expected" ]; then
    pass "PodDisruptionBudget/${name} minAvailable == ${expected}"
  else
    fail "PodDisruptionBudget/${name} minAvailable: expected ${expected}, got '${actual:-<not found>}'"
  fi
}
assert_pdb_min_available "$RENDERED" "n8n-main" "1"

# ── Redis command/Bull prefix synchronization (task 7.1) ───────────────────
# A third render with redis.prefix set (the chart's Bull-queue prefix) and
# env.shared carrying N8N_REDIS_KEY_PREFIX (the module's command-channel
# override, n8n.tf), both set to the same var.redis_key_prefix value. Proves
# the chart renders QUEUE_BULL_PREFIX from redis.prefix and the module's
# N8N_REDIS_KEY_PREFIX literal into the SAME shared ConfigMap, reaching main,
# worker and webhook-processor together through the one shared envFrom
# reference asserted above, so a caller-set prefix reaches n8n's command
# channel and its Bull queue keys together, not just one of the two.
cat >"$WORKDIR/fixture-redis-prefix.yaml" <<'EOF'
multiMain:
  enabled: true
  replicas: 2
queueMode:
  enabled: true
  workerReplicaCount: 3
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
env:
  shared:
    N8N_REDIS_KEY_PREFIX: myprefix
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

echo "==> helm template (redis-prefix fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-redis-prefix.yaml" "$WORKDIR/helm-stderr-redis-prefix.log" n8n-chart-check -f "$WORKDIR/fixture-redis-prefix.yaml"; then
  cat "$WORKDIR/helm-stderr-redis-prefix.log" >&2
  fail "helm template (redis-prefix fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the redis-prefix fixture with no credentials"
  RP_RENDERED="$WORKDIR/rendered-redis-prefix.yaml"
  assert_configmap_value "$RP_RENDERED" "n8n" "QUEUE_BULL_PREFIX" "myprefix"
  assert_configmap_value "$RP_RENDERED" "n8n" "N8N_REDIS_KEY_PREFIX" "myprefix"
  assert_envfrom_ref "$RP_RENDERED" "n8n-main" "n8n"
  assert_envfrom_ref "$RP_RENDERED" "n8n-worker" "n8n"
  assert_envfrom_ref "$RP_RENDERED" "n8n-webhook-processor" "n8n"
fi

# ── Public editor/webhook URLs (task 19.1) ──────────────────────────────────
# Chart 2.0 computes N8N_WEBHOOK_URL/N8N_EDITOR_BASE_URL from the chart-native
# webhook.url/editor.url keys (decision 0012); the module sets those directly
# instead of 1.x's config.extraEnv literals. WEBHOOK_URL (the pre-2.30.0
# legacy name) has no chart-native key at all in 2.0, so a module that still
# needs it for an older image sets it as a plain env.shared literal; this
# fixture proves all three coexist without a chart/module collision, with
# distinct editor and webhook hosts so a passing render proves the chart
# keeps the two independent rather than collapsing to one host.
cat >"$WORKDIR/fixture-public-urls.yaml" <<'EOF'
editor:
  url: "https://editor.example.test"
webhook:
  url: "https://hooks.example.test"
env:
  shared:
    WEBHOOK_URL: "https://hooks.example.test"
EOF

echo "==> helm template (public-urls fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-public-urls.yaml" "$WORKDIR/helm-stderr-public-urls.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-public-urls.yaml"; then
  cat "$WORKDIR/helm-stderr-public-urls.log" >&2
  fail "helm template (public-urls fixture) exited non-zero; see stderr above."
else
  pass "helm template rendered the public-urls fixture with no credentials"
  PU_RENDERED="$WORKDIR/rendered-public-urls.yaml"
  assert_configmap_value "$PU_RENDERED" "n8n" "N8N_EDITOR_BASE_URL" "https://editor.example.test"
  assert_configmap_value "$PU_RENDERED" "n8n" "N8N_WEBHOOK_URL" "https://hooks.example.test"
  assert_configmap_value "$PU_RENDERED" "n8n" "WEBHOOK_URL" "https://hooks.example.test"
  assert_envfrom_ref "$PU_RENDERED" "n8n-main" "n8n"
  assert_envfrom_ref "$PU_RENDERED" "n8n-worker" "n8n"
  assert_envfrom_ref "$PU_RENDERED" "n8n-webhook-processor" "n8n"
fi

# ── Caller-managed volumes coexist with the managed Redis CA (task 10.2) ────
# A render combining the module's own Redis CA secret volume/mount with
# caller-declared ConfigMap, Secret, and PVC volumes (local.
# n8n_caller_extra_volumes/n8n_caller_extra_volume_mounts in locals.tf,
# concatenated after the Redis CA entry in n8n.tf), exactly as multiple
# n8n_extra_volumes sources would render together. `helm template` needs no
# cluster and never looks up the named ConfigMap/Secret/PVC, so a passing
# render here proves the module creates and reads none of the caller's
# referenced objects; it only emits references to them. extraVolumes/
# extraVolumeMounts are unrelated to the env/Secret model chart 2.0 changed,
# so this section's fixture and assertions carry over unchanged.
cat >"$WORKDIR/fixture-caller-volumes.yaml" <<'EOF'
multiMain:
  enabled: true
  replicas: 2
queueMode:
  enabled: true
  workerReplicaCount: 3
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

echo "==> helm template (caller-volumes fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-caller-volumes.yaml" "$WORKDIR/helm-stderr-caller-volumes.log" n8n-chart-check -f "$WORKDIR/fixture-caller-volumes.yaml"; then
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
# set: local.n8n_database_ssl_values merged into `database`. Chart 2.0 renders
# DB_POSTGRESDB_SSL_ENABLED/DB_POSTGRESDB_SSL_CA straight from
# database.ssl.enabled/database.ssl.ca into the shared ConfigMap itself now
# (templates/_env.tpl's chartEnv), so the module no longer needs its own
# config.extraEnv duplicate of DB_POSTGRESDB_SSL_ENABLED/
# DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED (that list is retired anyway). This
# render proves the chart:
#   - puts the CA in the shared ConfigMap as DB_POSTGRESDB_SSL_CA and renders
#     no DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED when rejectUnauthorized=true,
#   - every role reaches it through the single shared envFrom reference
#     asserted earlier,
#   - changes each role's checksum/config annotation when the CA changes,
#     which is what rolls the pods and lets an atomic rollback restore the CA.
pg_ca_fixture() {
  printf '%s\n' \
    'database:' \
    '  ssl:' \
    '    enabled: true' \
    '    rejectUnauthorized: true' \
    "    ca: \"-----BEGIN CERTIFICATE-----\\n$1\\n-----END CERTIFICATE-----\""
}
pg_ca_fixture "U1lOVEhFVElDLUNBLUE=" >"$WORKDIR/fixture-postgres-ca-a.yaml"
pg_ca_fixture "U1lOVEhFVElDLUNBLUI=" >"$WORKDIR/fixture-postgres-ca-b.yaml"

PG_RENDER_OK=1
for pg_variant in a b; do
  echo "==> helm template (postgres-ca-${pg_variant} fixture) ${CHART_DISPLAY}"
  if ! render_chart "$WORKDIR/rendered-postgres-ca-${pg_variant}.yaml" "$WORKDIR/helm-stderr-postgres-ca-${pg_variant}.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-postgres-ca-${pg_variant}.yaml"; then
    fail "helm template (postgres-ca-${pg_variant} fixture) failed: $(cat "$WORKDIR/helm-stderr-postgres-ca-${pg_variant}.log")"
    PG_RENDER_OK=0
  fi
done

if [ "$PG_RENDER_OK" = "1" ]; then
  pass "helm template rendered both postgres-ca fixtures with no credentials"

  # assert_configmap_ca_block <file> <configmap-name> <base64-body>
  # DB_POSTGRESDB_SSL_CA contains embedded newlines, so the chart renders it
  # as a YAML block scalar (`|-`) across 4 fixed lines rather than a single
  # quoted string.
  assert_configmap_ca_block() {
    local file="$1" cmname="$2" body="$3" expected actual
    expected="$(printf '  DB_POSTGRESDB_SSL_CA: |-\n    -----BEGIN CERTIFICATE-----\n    %s\n    -----END CERTIFICATE-----' "$body")"
    actual="$(manifest_block "$file" ConfigMap "$cmname" | awk '
      /^  DB_POSTGRESDB_SSL_CA: \|-$/ { print; getline; print; getline; print; getline; print; exit }
    ')"
    if [ "$actual" = "$expected" ]; then
      pass "ConfigMap/${cmname} renders DB_POSTGRESDB_SSL_CA with the supplied PEM"
    else
      fail "ConfigMap/${cmname} DB_POSTGRESDB_SSL_CA: expected the supplied PEM block, got: ${actual:-<not found>}"
    fi
  }

  assert_configmap_ca_block "$WORKDIR/rendered-postgres-ca-a.yaml" "n8n" "U1lOVEhFVElDLUNBLUE="
  assert_configmap_value "$WORKDIR/rendered-postgres-ca-a.yaml" "n8n" "DB_POSTGRESDB_SSL_ENABLED" '"true"'
  assert_configmap_key_absent "$WORKDIR/rendered-postgres-ca-a.yaml" "n8n" "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED"
  assert_configmap_key_absent "$WORKDIR/rendered-postgres-ca-a.yaml" "n8n" "DB_POSTGRESDB_SSL_CA_FILE"

  for pg_role in n8n-main n8n-worker n8n-webhook-processor; do
    assert_envfrom_ref "$WORKDIR/rendered-postgres-ca-a.yaml" "$pg_role" "n8n"

    # A different CA must change this role's checksum/config annotation,
    # because the shared ConfigMap it reads from is part of every role's
    # checksum (templates/_env.tpl's envChecksum).
    pg_block="$(manifest_block "$WORKDIR/rendered-postgres-ca-a.yaml" Deployment "$pg_role")"
    pg_sum_a="$(printf '%s\n' "$pg_block" | sed -nE 's/^[[:space:]]+checksum\/config: ([0-9a-f]+)$/\1/p' | head -1)"
    pg_sum_b="$(manifest_block "$WORKDIR/rendered-postgres-ca-b.yaml" Deployment "$pg_role" | sed -nE 's/^[[:space:]]+checksum\/config: ([0-9a-f]+)$/\1/p' | head -1)"
    if [ -n "$pg_sum_a" ] && [ -n "$pg_sum_b" ] && [ "$pg_sum_a" != "$pg_sum_b" ]; then
      pass "postgres-ca: Deployment/${pg_role} checksum/config changes with the CA"
    else
      fail "postgres-ca: Deployment/${pg_role} checksum/config did not change with the CA (a='${pg_sum_a:-<none>}', b='${pg_sum_b:-<none>}')"
    fi
  done
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
# changing what `terraform apply` does to live replica counts. Unrelated to
# the env/Secret model chart 2.0 changed.
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

echo "==> helm template (keda-on fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-keda-on.yaml" "$WORKDIR/helm-stderr-keda-on.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-keda-on.yaml"; then
  fail "helm template (keda-on fixture) failed: $(cat "$WORKDIR/helm-stderr-keda-on.log")"
else
  KEDA_WORKER_REPLICAS="$(manifest_block "$WORKDIR/rendered-keda-on.yaml" Deployment n8n-worker | sed -nE 's/^  replicas: (.*)$/\1/p' | head -1)"
  if [ -z "$KEDA_WORKER_REPLICAS" ]; then
    pass "keda-on: Deployment/n8n-worker renders no replicas field (KEDA owns the count)"
  else
    fail "keda-on: Deployment/n8n-worker still renders replicas: ${KEDA_WORKER_REPLICAS}; chart no longer defers the worker count to KEDA"
  fi

  assert_deployment_replicas "$WORKDIR/rendered-keda-on.yaml" "n8n-webhook-processor" "1"

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
# the chart's own default. N8N_GRACEFUL_SHUTDOWN_TIMEOUT rendered into a
# ConfigMap in both 1.x and 2.0 (only the ConfigMap's name/contents around it
# changed), so this section's grep-based assertions carry over unchanged.
# That default is compared against local.n8n_chart_default_graceful_shutdown_timeout
# (read straight from locals.tf, since this script runs no Terraform), which
# the graceful_shutdown_fits_grace_period check relies on, so a chart bump
# that moves the default fails here until that local is updated.
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
  if ! render_chart "$WORKDIR/configmap-$scenario.yaml" "$WORKDIR/helm-graceful-shutdown-$scenario.err" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-graceful-shutdown-$scenario.yaml" --show-only templates/configmap.yaml; then
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
# Unrelated to the env/Secret model chart 2.0 changed.
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
echo "==> helm template (keda paused fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-keda-paused.yaml" "$WORKDIR/helm-stderr-keda-paused.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-keda-on.yaml" -f "$WORKDIR/fixture-keda-paused.yaml"; then
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
# Unrelated to the env/Secret model chart 2.0 changed.
deployment_has_container() {
  # deployment_has_container <rendered-file> <deployment-name> <container-name>
  manifest_block "$1" Deployment "$2" | awk -v ctr="$3" '
    $0 == "        - name: " ctr { print "yes"; exit }
  '
}
cat >"$WORKDIR/fixture-task-runners.yaml" <<'EOF'
taskRunners:
  enabled: true
EOF
echo "==> helm template (task-runners fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-task-runners.yaml" "$WORKDIR/helm-stderr-task-runners.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-task-runners.yaml"; then
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

# ── Image pull Secrets render natively, ServiceAccount stays chart-owned
# (n8n-hosting#180, chart >= 2.0.0) ─────────────────────────────────────────
# Chart 2.0 renders imagePullSecrets straight onto every n8n pod and the
# Helm test pod; the module passes var.n8n_image_pull_secrets through as that
# top-level value and no longer takes over the chart's own ServiceAccount
# (no kubernetes_service_account_v1.n8n resource; see n8n.tf/AGENTS.md). This
# proves the chart still creates and Workload-Identity-annotates its own
# ServiceAccount under the module's default name while pull secrets are set.
cat >"$WORKDIR/fixture-image-pull-secrets.yaml" <<'EOF'
imagePullSecrets:
  - name: ar-pull-creds
serviceAccount:
  create: true
  name: n8n
  annotations:
    iam.gke.io/gcp-service-account: n8n-wi@test-project.iam.gserviceaccount.com
EOF
echo "==> helm template (image-pull-secrets fixture) ${CHART_DISPLAY}"
if ! render_chart "$WORKDIR/rendered-image-pull-secrets.yaml" "$WORKDIR/helm-stderr-image-pull-secrets.log" n8n-chart-check -f "$WORKDIR/fixture-values.yaml" -f "$WORKDIR/fixture-image-pull-secrets.yaml"; then
  fail "helm template (image-pull-secrets fixture) failed: $(cat "$WORKDIR/helm-stderr-image-pull-secrets.log")"
else
  for role in n8n-main n8n-worker n8n-webhook-processor; do
    if manifest_block "$WORKDIR/rendered-image-pull-secrets.yaml" Deployment "$role" | grep -qF -- "- name: ar-pull-creds"; then
      pass "image pull secrets: Deployment/${role} carries imagePullSecrets"
    else
      fail "image pull secrets: Deployment/${role} has no imagePullSecrets entry with n8n_image_pull_secrets set"
    fi
  done
  if manifest_block "$WORKDIR/rendered-image-pull-secrets.yaml" ServiceAccount "n8n" | grep -qF "iam.gke.io/gcp-service-account: n8n-wi@test-project.iam.gserviceaccount.com"; then
    pass "image pull secrets: the chart's own ServiceAccount/n8n keeps its Workload Identity annotation"
  else
    fail "image pull secrets: ServiceAccount/n8n is missing its Workload Identity annotation; the module must not take over ServiceAccount ownership (chart 2.0 owns it via serviceAccount.create=true)"
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
  manifest_block() {
    awk -v kind="kind: $2" -v name="  name: $3" '
      /^---$/ { if (found) exit; in_kind = 0; found = 0; next }
      $0 == kind { in_kind = 1 }
      in_kind && $0 == name { found = 1 }
      found { print }
    ' "$1"
  }
  assert_deployment_replicas() {
    local file="$1" name="$2" expected="$3" actual
    actual="$(manifest_block "$file" Deployment "$name" | sed -nE 's/^  replicas: (.*)$/\1/p' | head -1)"
    if [ "$actual" = "$expected" ]; then
      pass "Deployment/${name} replicas == ${expected}"
    else
      fail "Deployment/${name} replicas: expected ${expected}, got '${actual:-<not found>}'"
    fi
  }
  assert_deployment_replicas "$RENDERED" "n8n-main" "999"
  echo "FAILURES=$FAILURES"
)"

if echo "$SELFTEST_OUTPUT" | grep -q "^FAILURES=1$"; then
  pass "self-check: an intentionally wrong expected value is caught as a failure"
else
  fail "self-check: assert_deployment_replicas did not catch a deliberately wrong expected value (dump: $SELFTEST_OUTPUT)"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "check-n8n-chart.sh: ${FAILURES} check(s) failed" >&2
  exit 1
fi

echo "check-n8n-chart.sh: all checks passed"
