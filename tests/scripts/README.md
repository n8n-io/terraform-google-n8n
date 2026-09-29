# Smoke test

Post-deployment smoke test for `terraform-google-n8n`. Verifies the queue-mode deployment (single-main or multi-main) is healthy end to end, pod health, queue mode, KEDA, HTTPS, API, and a full webhook → worker execution.

`smoke-test.sh` is read-only inspection. It never drains a Redis queue,
restarts a Deployment, rotates or reads a Secret's contents, or applies
infrastructure, whether run manually or from CI. The one exception is the
opt-in `LOAD_TEST=true` load-generation flag (see
[Worker scaling test](#worker-scaling-test-opt-in)), which creates and deletes
a temporary n8n workflow and fires webhook requests; it is off by default and
never runs in CI. Manual-only runtime scenarios (encryption-key recovery,
Redis prefix/persistence transitions, license verification, credential
rotation restarts) are covered by
[`docs/manual-verification-checklist.md`](../../docs/manual-verification-checklist.md),
not by this script.

## Worker pools verification (`verify-worker-pools.sh`, EARLY ALPHA)

`verify-worker-pools.sh` is a companion to the smoke test above, for a
deployment that declares `n8n_worker_pools` (see
[`examples/worker-pools`](../../examples/worker-pools/)). It answers a
question nothing at plan time can: did the pinned Helm chart actually render
`queueMode.workerGroups`. A chart that predates the feature accepts the key
and renders nothing for it, so `terraform apply` succeeds with
`N8N_WORKER_POOLS_ENABLED` switched on and no pool Deployment or
`ScaledObject` behind it. Run it from the example directory that holds
Terraform state, the same convention as the smoke test:

```bash
cd examples/worker-pools
../../tests/scripts/verify-worker-pools.sh
```

It counts the rendered pool Deployments/ScaledObjects against the
`worker_pool_names` output, checks each pool's `N8N_WORKER_POOL_NAME` env var
and KEDA trigger metadata against the default worker's, and confirms
`N8N_WORKER_POOLS_ENABLED=true` reached the mains. CI cannot run this: it
needs a live cluster. Same manual-verification tier as the smoke test.

## Chart-rendering regression check (`check-n8n-chart.sh`)

`check-n8n-chart.sh` is a separate, credential-free check that renders the
pinned n8n Helm chart (`var.n8n_chart_version` / `var.n8n_chart_repository`)
with a synthetic values fixture and asserts on the rendered Kubernetes
manifests: replica-count floor seeding on the main/worker/webhook-processor
Deployments, the `service.annotations` BackendConfig annotation reaching both
the main and webhook-processor Services, and the four
`EXECUTIONS_DATA_SAVE_*` env vars, plus the `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`
ConfigMap entry against `local.n8n_chart_default_graceful_shutdown_timeout`.
It first fails fast if its own chart pins differ from the module's
`n8n_chart_repository` / `n8n_chart_version` defaults. It needs `helm` and
`python3` on `PATH` (`python3` for `lib/tf-defaults.sh`, which reads those
defaults from `variables.tf`), no Terraform, no Kubernetes cluster, and no
cloud credentials:

```bash
tests/scripts/check-n8n-chart.sh
```

This proves the chart renders these value fragments the way the module
assumes; it is not a live Helm upgrade or a proof of runtime behavior, and it
does not exercise the module's own Terraform expressions (covered by the
mocked plan-time `terraform test` suite at the module root).

## Two-pass checkov security baseline (`check-checkov.sh`)

`check-checkov.sh` runs the module's pinned checkov baseline (see
`AGENTS.md`, "Static analysis") twice: once against the default tfvars, and
once against [`tests/checkov/opt-in.tfvars`](../checkov/opt-in.tfvars), which
flips on every switch that gates a resource defaulting to count 0.
checkov answers every check on a count-0 resource `UNKNOWN`, not `FAILED`,
so a resource behind a default-`false` toggle (e.g. `redis_exporter_enabled`)
never appears in the report at all under the default pass alone. The
opt-in pass additionally verifies checkov actually *evaluated* every
resource in its own `REQUIRED_OPT_IN_RESOURCES` list, not just that the
run exited 0:

```bash
tests/scripts/check-checkov.sh
```

Requires `checkov` (pinned to the version `.github/workflows/terraform-tests.yml`'s
`checkov` job uses) and `python3` on `PATH`. No credentials, no cluster: checkov
statically parses the Terraform source and its resolved variable defaults/tfvars.

Adding a new count-gated resource? Add its enabling switch to
`tests/checkov/opt-in.tfvars` and its resource address to this script's
`REQUIRED_OPT_IN_RESOURCES`, or the opt-in pass silently stops reaching it.

## Version-currency reports (`check-version-drift.sh`, `check-helm-chart-coverage.sh`, `chart-values-diff.sh`)

Report-only; none of these three write or bump a pin. See
[`docs/versioning.md`](../../docs/versioning.md) for the full pin inventory
and bump-tier classification these scripts check against.

- **`check-version-drift.sh`**: compares every Terraform provider (via the
  Terraform Registry API), the n8n chart (via GHCR's anonymous tag API), and
  the KEDA chart (via its Helm repo) against the currently pinned version.
  Every lookup failure is reported as an explicit `ERROR`, distinct from "no
  drift found", so a network hiccup cannot look like a clean report. Exit
  code is nonzero only on a lookup failure, never on drift alone.
- **`check-helm-chart-coverage.sh`**: fails when
  [`docs/helm-chart-coverage.md`](../../docs/helm-chart-coverage.md)'s
  declared chart version disagrees with `n8n_chart_version`'s default, or
  when the pinned chart's `values.yaml` has a top-level key the doc never
  mentions.
- **`chart-values-diff.sh <candidate-version>`**: diffs the pinned chart's
  `values.yaml` against a candidate version, e.g.
  `tests/scripts/chart-values-diff.sh 1.12.0`. Manual, run when picking up a
  chart bump; exits nonzero only if a `helm show values` call itself fails
  (bad version, unreachable registry), never because a diff was found.

```bash
tests/scripts/check-version-drift.sh
tests/scripts/check-helm-chart-coverage.sh
```

Requires `helm` and `python3` on `PATH`. No Google Cloud credentials.

## What it covers

| Check | What it verifies |
|---|---|
| kubectl cluster connectivity | kubectl can reach the GKE cluster |
| Namespace exists | The configured namespace is present |
| Main / worker / webhook-processor pod health | Each deployment is at the expected ready replica count |
| Task runner sidecar (workers) | Runner sidecar is present on worker pods and connected to the broker |
| Main topology | Detects single-main vs multi-main from the chart-rendered `N8N_MULTI_MAIN_SETUP_ENABLED` entry on the `n8n-main` Deployment spec. Multi-main: the flag is `true` in the pod and leadership activity shows in main logs. Single-main: the flag is off (or staged by `n8n_main_leader_election_enabled`), the main HPA is 1/1 (or 1 replica without a module HPA), the strategy is `Recreate`, and PDB `minAvailable=0` |
| Autoscalers | KEDA `ScaledObject` (workers, queue-depth) and HPAs (main, webhook-processor) |
| Redis connectivity | Worker pods see `QUEUE_BULL_REDIS_HOST` and queue-related log activity |
| HTTPS reachability | `/healthz` returns HTTP 200 over the ALB hostname |
| HTTP → HTTPS redirect | Port 80 redirects to HTTPS |
| API connectivity (if API key set) | `/api/v1/workflows` responds with 200 |
| Workflow execution (if API key set) | Creates a webhook → set workflow, fires it, confirms success, deletes it |
| Worker scaling (opt-in) | Queues CPU-burning executions and confirms workers scale up |
| Redis namespace isolation | Bull queue prefix (`QUEUE_BULL_PREFIX`) and command-channel prefix (`N8N_REDIS_KEY_PREFIX`) match on worker pods |
| Redis exporter (opt-in) | `redis-exporter` Deployment/Service exist and are ready when `redis_exporter_enabled = true` |
| Reference-only mounts | Credentials-overwrite file and task-runner custom launcher config are readable when configured (content never read) |
| Runtime settings | `NODE_OPTIONS` heap ceiling and pod `dnsConfig` reported when configured |
| License Secret | Managed `n8n-license-secret` Secret exists when `n8n_license_key` is set (existence only, never read) |
| Additional ingress hostnames | Every `n8n_ingress_hosts` entry responds on `/healthz` |

## Quick start

The script reads `n8n_kube_namespace`, `n8n_url`, and `kubectl_config_command` automatically from `terraform output`.

```bash
cd examples/small              # or wherever your terraform.tfstate lives
../../tests/scripts/smoke-test.sh
```

The script automatically:

1. Reads `n8n_kube_namespace` and `n8n_url` from Terraform state
2. Runs the `kubectl_config_command` output to point kubectl at the right cluster
3. Runs all checks and prints a pass / fail / warn / skip summary

> **Note:** Run the script from the directory that holds `terraform.tfstate` (e.g. `examples/small/`), not from `tests/scripts/`. The script calls `terraform output` against the current working directory by default.

## API key (required for API and execution tests)

The API connectivity and workflow execution checks need an n8n API key. Without one, those checks are skipped with a warning.

1. Open your n8n instance in a browser.
2. Go to **Settings → API → Create API Key**.
3. Copy the key.

Set it before running the script:

```bash
N8N_API_KEY=your-key-here ../../tests/scripts/smoke-test.sh
```

Or persist it in a `.env` file. The script looks for `.env` next to itself first, then in the current working directory:

```bash
cp ../../tests/scripts/.env.example ../../tests/scripts/.env
# edit .env, set N8N_API_KEY, then:
../../tests/scripts/smoke-test.sh
```

## Configuration

All settings can be overridden via environment variables or a `.env` file.

| Variable | Default | Description |
|---|---|---|
| `TERRAFORM_DIR` | `$(pwd)` | Path to Terraform directory to read state from |
| `N8N_URL` | *(from `terraform output`)* | Base URL of the n8n deployment |
| `NAMESPACE` | *(from `terraform output`)* | Kubernetes namespace |
| `N8N_API_KEY` |, | API key for API and workflow execution tests |
| `LOAD_TEST` | `false` | Set to `true` to run the worker scaling test |
| `LOAD_REQUESTS` | `100` | Webhook executions to fire during the load test |
| `LOAD_CONCURRENCY` | `20` | Concurrent in-flight webhook calls |
| `LOAD_SEED_JOBS` | `20` | Jobs queued in phase 1 to trigger the autoscaler |
| `LOAD_JOB_DURATION_SECS` | `10` | CPU burn per worker job (seconds) |
| `SCALE_WAIT_SECS` | `180` | Seconds to wait for the autoscaler to react |

**Priority:** `.env` values → environment variables → Terraform outputs → built-in defaults.

## Worker scaling test (opt-in)

The scaling test creates real load and is therefore opt-in:

```bash
LOAD_TEST=true N8N_API_KEY=your-key ../../tests/scripts/smoke-test.sh
```

What it does:

1. Pre-checks the autoscaler, KEDA `ScaledObject` (preferred for workers) or CPU-based HPA. Skips if neither is found, or if HPA metrics are `<unknown>` (metrics-server not ready).
2. Creates a temporary n8n workflow with a Code node that burns CPU for `LOAD_JOB_DURATION_SECS` seconds per execution.
3. Activates it and queues `LOAD_SEED_JOBS` webhook calls in phase 1 to trigger the autoscaler.
4. Polls every 15 seconds for up to `SCALE_WAIT_SECS` seconds, watching worker replicas climb.
5. Once scale-up is detected, queues the remaining `LOAD_REQUESTS - LOAD_SEED_JOBS` calls (phase 2) so the new workers visibly pick up jobs.
6. Deactivates and deletes the test workflow (cleanup runs even on failure).

If workers don't scale within the wait window, the script warns and suggests increasing `LOAD_REQUESTS` or `LOAD_JOB_DURATION_SECS`.

## Running against a remote deployment

You can run without local Terraform state, for example against a cluster managed by someone else, by setting everything explicitly:

```bash
NAMESPACE=n8n \
N8N_URL=https://n8n.example.com \
N8N_API_KEY=your-key \
./tests/scripts/smoke-test.sh
```

You're responsible for pointing kubectl at the right cluster yourself in that case (the script only switches contexts when it can read `kubectl_config_command` from Terraform).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed (warnings are non-fatal) |
| `1` | One or more checks failed |

The summary line always prints the counts: `Passed: X  Failed: Y  Warnings: Z  Skipped: W`.
