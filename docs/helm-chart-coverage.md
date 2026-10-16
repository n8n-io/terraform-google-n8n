# n8n Helm chart coverage

Every top-level key in the pinned n8n Helm chart's `values.yaml`
(`n8n_chart_version` default: **2.0.0**, `oci://ghcr.io/n8n-io/n8n-helm-chart/n8n`),
and how this module surfaces it, if at all. Kept honest by
`tests/scripts/check-helm-chart-coverage.sh`, which fails when this file's
declared chart version disagrees with `variables.tf`'s `n8n_chart_version`
default, or when the pinned chart's `values.yaml` has gained a top-level key
this table never mentions.

Chart 2.0 is the unreleased line on the n8n-hosting `main` branch (latest
tag: `v1.16.0`; `n8n_chart_version` default: **2.0.0**, built from a local
chart checkout via `N8N_CHART_DIR` until a tagged release exists). Besides
`imagePullSecrets` (below), it folds in: env delivered as per-component maps
via `envFrom` instead of nine `extraEnv`/`extraEnvFrom` lists
(n8n-io/n8n-hosting#250); `editor.url`/`webhook.url` as the chart-native
source of `N8N_EDITOR_BASE_URL`/`N8N_WEBHOOK_URL`, dropping
`secretRefs.env.N8N_HOST`/`N8N_PORT`/`N8N_PROTOCOL` and `webhook.timeout`
(#250); worker liveness/readiness/startup probes moving from an always-true
`pgrep` exec check to the queue health HTTP endpoint (#233, no module
action: the module sets no `probes.worker.*`/`redis.healthCheck.*` value);
workers and webhook processors starting through the image entrypoint instead
of a bare `command: ["n8n"]`, so they now trust
`/opt/custom-certificates` the same way main does (#241, no module action:
the module sets no container `command`); and the chart failing the render on
any values key it retired, naming the replacement (#247, verified against
this module's own rendered values; none hit a retired key). See
`UPGRADING.md` in the chart repo and
[`docs/upgrading-n8n.md`](./upgrading-n8n.md).

| Chart key | Module surface | Notes |
| --- | --- | --- |
| `image` | `n8n_image_repository`, `n8n_image_tag` | |
| `imagePullSecrets` | `n8n_image_pull_secrets` | New top-level key in chart 2.0 (#180); the module passes the list straight through, attached to every n8n pod and the chart's own ServiceAccount. No module-managed ServiceAccount takeover |
| `nameOverride` | Not surfaced | No caller need identified; the module's own naming (`friendly_name_prefix`) already scopes resource names |
| `fullnameOverride` | Not surfaced | Same as `nameOverride` |
| `commonLabels` | Not surfaced directly | The module sets its own label set on the resources it creates; chart-level `commonLabels` would duplicate that without a documented gap |
| `commonAnnotations` | Not surfaced | No caller need identified |
| `queueMode` | `n8n_execution_concurrency_limit` (via `executions.concurrency.productionLimit`); worker replica/resource inputs | `queueMode.enabled` is always `true`; this module runs queue mode only. `queueMode.workerConcurrency` is left at the chart's new default (empty): chart 2.0 fails the render when both it and `executions.concurrency.productionLimit` set a worker's concurrency, so the module keeps only `productionLimit` (upstream guidance, decision 0012) |
| `webhookProcessor` | Webhook replica/resource inputs (`n8n_webhook_*`) | Always enabled |
| `multiMain` | `n8n_main_hpa_min_replicas`/`n8n_main_fixed_replicas` (topology derivation) | Single-main vs multi-main is derived from the effective main replica count, not set directly |
| `taskRunners` | `n8n_task_runners_enabled`, `n8n_task_runner_timeout`, `n8n_task_runner_custom_config` | Since chart 1.12.0 the sidecar renders on worker pods only in queue mode (n8n-hosting#179); main and webhook-processor pods carry none |
| `strategy` | Derived (`local.n8n_main_strategy`) | `Recreate` at one main replica (election staging), chart default above one |
| `podLabels` | Not surfaced | No caller need identified |
| `replicaCount` | Derived (`local.n8n_effective_main_replica_count`) | Always set explicitly, alongside `multiMain.replicas`, so an upstream chart default change cannot silently change single-main replica count unnoticed (set since the 0.4.0 topology work) |
| `service` | `n8n_main_service_annotations`-equivalent wiring (BackendConfig) | |
| `ingress` | Not surfaced (chart-level) | This module disables the chart's own Ingress and manages its own `kubernetes_ingress_v1.n8n` in `n8n.tf`, including the `/mcp` route the chart's Ingress would otherwise add |
| `persistence` | Not surfaced | n8n's binary/execution data goes to Cloud SQL/GCS (`n8n_execution_data_storage_mode`), not a chart-managed PVC |
| `extraObjects` | Not surfaced | New top-level key in chart 2.0 (arbitrary extra manifests rendered alongside the release); no caller need identified |
| `extraVolumes` | `n8n_extra_volumes` (merged with module-managed CA/credential-overwrite mounts) | |
| `extraVolumeMounts` | `n8n_extra_volume_mounts` (merged) | |
| `extraContainers` | Not surfaced | No sidecar-injection need identified; would need its own security-review contract before exposing |
| `extraInitContainers` | Not surfaced | Same as `extraContainers` |
| `dnsPolicy` | Not surfaced | |
| `dnsConfig` | `n8n_dns_config` | |
| `hostAliases` | Not surfaced | New top-level key in chart 2.0; no caller need identified |
| `resources` | `n8n_main_*`/`n8n_worker_*`/`n8n_webhook_*` CPU/memory request/limit inputs | |
| `nodeSelector` | Not surfaced | No caller need identified; node placement is via the module-managed node pool |
| `tolerations` | Not surfaced | Same as `nodeSelector` |
| `affinity` | Derived (`multiMain.antiAffinity`) only | No general pod affinity/anti-affinity escape hatch |
| `nodePlacement` | Not surfaced | |
| `securityContext` | Not surfaced (chart default retained) | Renamed/split in chart 2.0 into `podSecurityContext`/`containerSecurityContext` below; this key is the remaining top-level alias the chart still reads |
| `podSecurityContext` | Not surfaced (chart default retained) | New top-level key in chart 2.0; the chart's own default pod security context is not currently overridden |
| `containerSecurityContext` | Not surfaced (chart default retained) | New top-level key in chart 2.0; same as `podSecurityContext` |
| `rbac` | Not surfaced | Chart defaults retained |
| `serviceAccount` | Derived (annotated for Workload Identity, `var.n8n_kube_svc_account` for the name) | The chart always creates and owns this account; `n8n_image_pull_secrets` attaches through the top-level `imagePullSecrets` value above, not through a serviceAccount override |
| `networkPolicy` | Not surfaced | No `NetworkPolicy` resource is created by this module |
| `probes` | Not surfaced (chart defaults retained) | Worker liveness/readiness/startup default to the queue health HTTP endpoint since #233 (previously an always-true `pgrep` exec check); the module sets no `probes.worker.*` override |
| `lifecycle` | `n8n_termination_grace_period` (main preStop only) | |
| `hpa` | `n8n_main_hpa_*`, standalone webhook HPA | |
| `keda` | `n8n_worker_keda_enabled`, worker KEDA tuning inputs, `n8n_worker_keda_pause`/`n8n_worker_keda_paused_replica_count` | `keda.webhookProcessor.*` (including its `pause`) is not surfaced: webhook processors are scaled by the module's own external HPA (`scaling.tf`), so no chart `ScaledObject` exists for it |
| `pdb` | Not set by the module; chart default (`pdb.enabled: true`, `pdb.minAvailable: 1`) | Chart-gated (decision 0004): renders a main PodDisruptionBudget only when main can run more than one pod (effective replicas > 1, or `hpa.main` enabled with `minReplicas` > 1); at one main replica the chart renders no PDB, so node drains are not blocked |
| `webhook` | `n8n_webhook_url` (via `webhook.url`); see `webhookProcessor` for the replica/resource surface | Chart 2.0 renders `N8N_WEBHOOK_URL` from `webhook.url` itself (decision 0012); the module no longer emits that variable as a literal. `webhook.timeout` was retired in 2.0 (never read by n8n) and is not set |
| `editor` | `n8n_fqdn` (via `editor.url`) | New top-level key in chart 2.0. The module always sets `editor.url = "https://<n8n_fqdn>"`, so the chart renders `N8N_EDITOR_BASE_URL` itself; the module no longer emits that variable as a literal |
| `executions` | `n8n_execution_timeout`, `n8n_execution_timeout_max`, `n8n_execution_concurrency_limit`, `n8n_executions_data_save_*` | |
| `env` | `n8n_timezone`, `n8n_extra_env`, `n8n_worker_extra_env`, and the module's large set of dedicated `N8N_*`/`DB_*`/`QUEUE_*` inputs (via `env.shared`/`env.worker`) | Replaces 1.x's nine `extraEnv` lists (`config.extraEnv`, `queueMode.workerExtraEnv`, etc., all retired in 2.0). Most application-level tuning flows through `env.shared` as environment variables, not chart-native config keys. The module uses only `env.shared` and `env.worker`; it has nothing component-specific for `env.main`/`env.webhookProcessor`/`env.taskRunner` |
| `chartEnvOverrides` | Not surfaced | New top-level key in chart 2.0 (deliberately overrides a variable the chart itself computes). The module never needs to override a chart-computed variable, so it is always empty |
| `envFrom` | Not surfaced | New top-level key in chart 2.0 (load a whole ConfigMap/Secret per component). No caller need identified |
| `config` | `n8n_timezone` (`config.timezone`) | In chart 1.x this also carried `config.extraEnv`; chart 2.0 retired that list (see `env` above). `config.timezone` is the only key left under `config` |
| `license` | `n8n_license_key`, `n8n_license_key_secret_ref` | |
| `secretRefs` | Derived (`local.effective_core_secret_name`) | The chart's Secret now holds only `N8N_ENCRYPTION_KEY`/`N8N_LICENSE_ACTIVATION_KEY`; `secretRefs.env.N8N_HOST`/`N8N_PORT`/`N8N_PROTOCOL` were retired in chart 2.0 (`N8N_PORT` now comes from `service.port`, host/protocol from `editor.url`/`webhook.url`) and the module never sets them |
| `database` | `postgres_*` inputs, `n8n_database_*` external-database inputs, `db_postgresdb_ssl_ca_pem` (`database.ssl.*`) | `database.ssl` is set only while a PostgreSQL CA is delivered (`enabled = true`, `rejectUnauthorized = true`, `ca`); chart 2.0 renders `DB_POSTGRESDB_SSL_ENABLED`/`DB_POSTGRESDB_SSL_CA` from those chart-native keys itself, so the module emits no `DB_POSTGRESDB_SSL_*` literal on that path (doing so would collide with the chart's own value and fail the render, decision 0012). On the non-CA `db_postgresdb_ssl_enabled = true` path, `database.ssl.enabled` stays `false` and the module still sets `DB_POSTGRESDB_SSL_ENABLED`/`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` directly in `env.shared`, since the chart does not own those names there. `database.ssl.cert`/`key` (client certificates) are not surfaced. See [`docs/postgresql-tls.md`](./postgresql-tls.md) |
| `redis` | `redis_*` inputs, KEDA/queue wiring, `n8n_queue_worker_lock_duration`/`n8n_queue_worker_lock_renew_time`/`n8n_queue_worker_stalled_interval`/`n8n_graceful_shutdown_timeout` (`redis.worker.*`) | `redis.worker.maxStalledCount` is not surfaced. `redis.healthCheck.*` (new in #233, worker probe endpoint) is left at the chart's own default (enabled, port 5678) |
| `s3` | `gcs_*` inputs (S3-compatible driver over GCS + HMAC) | |

## Verifying this table

```bash
tests/scripts/check-helm-chart-coverage.sh
```

Requires `helm` on `PATH`; pulls the pinned chart from the public OCI
registry (no credentials). Fails if the chart version this file names above
disagrees with `variables.tf`'s `n8n_chart_version` default, or if the
chart's actual `values.yaml` has a top-level key not listed in the table
above.

`N8N_CHART_DIR=/path/to/n8n-hosting/charts/n8n tests/scripts/check-helm-chart-coverage.sh`
reads that local chart checkout's `values.yaml` instead of pulling the
pinned OCI chart. Chart 2.0 is unreleased at the time this file targets it
(it is the current state of n8n-hosting `main`, past the latest tag);
use this during development against a local clone of that branch.
The declared-version-vs-`variables.tf` guard still runs either way.
