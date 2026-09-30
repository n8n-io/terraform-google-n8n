# n8n Helm chart coverage

Every top-level key in the pinned n8n Helm chart's `values.yaml`
(`n8n_chart_version` default: **1.14.0**, `oci://ghcr.io/n8n-io/n8n-helm-chart/n8n`),
and how this module surfaces it, if at all. Kept honest by
`tests/scripts/check-helm-chart-coverage.sh`, which fails when this file's
declared chart version disagrees with `variables.tf`'s `n8n_chart_version`
default, or when the pinned chart's `values.yaml` has gained a top-level key
this table never mentions.

| Chart key | Module surface | Notes |
| --- | --- | --- |
| `image` | `n8n_image_repository`, `n8n_image_tag` | |
| `nameOverride` | Not surfaced | No caller need identified; the module's own naming (`friendly_name_prefix`) already scopes resource names |
| `fullnameOverride` | Not surfaced | Same as `nameOverride` |
| `commonLabels` | Not surfaced directly | The module sets its own label set on the resources it creates; chart-level `commonLabels` would duplicate that without a documented gap |
| `commonAnnotations` | Not surfaced | No caller need identified |
| `queueMode` | `n8n_worker_concurrency`, worker replica/resource inputs | `queueMode.enabled` is always `true`; this module runs queue mode only |
| `webhookProcessor` | Webhook replica/resource inputs (`n8n_webhook_*`) | Always enabled |
| `multiMain` | `n8n_main_hpa_min_replicas`/`n8n_main_fixed_replicas` (topology derivation) | Single-main vs multi-main is derived from the effective main replica count, not set directly |
| `taskRunners` | `n8n_task_runners_enabled`, `n8n_task_runner_timeout`, `n8n_task_runner_custom_config` | Since chart 1.12.0 the sidecar renders on worker pods only in queue mode (n8n-hosting#179); main and webhook-processor pods carry none |
| `strategy` | Derived (`local.n8n_main_strategy`) | `Recreate` at one main replica (election staging), chart default above one |
| `podLabels` | Not surfaced | No caller need identified |
| `replicaCount` | Derived (`local.n8n_effective_main_replica_count`) | Always set explicitly, alongside `multiMain.replicas`, so an upstream chart default change cannot silently change single-main replica count unnoticed (set since the 0.4.0 topology work) |
| `service` | `n8n_main_service_annotations`-equivalent wiring (BackendConfig) | |
| `ingress` | Not surfaced (chart-level) | This module disables the chart's own Ingress and manages its own `kubernetes_ingress_v1.n8n` in `n8n.tf`, including the `/mcp` route the chart's Ingress would otherwise add |
| `persistence` | Not surfaced | n8n's binary/execution data goes to Cloud SQL/GCS (`n8n_execution_data_storage_mode`), not a chart-managed PVC |
| `extraVolumes` | `n8n_extra_volumes` (merged with module-managed CA/credential-overwrite mounts) | |
| `extraVolumeMounts` | `n8n_extra_volume_mounts` (merged) | |
| `extraContainers` | Not surfaced | No sidecar-injection need identified; would need its own security-review contract before exposing |
| `extraInitContainers` | Not surfaced | Same as `extraContainers` |
| `dnsPolicy` | Not surfaced | |
| `dnsConfig` | `n8n_dns_config` | |
| `resources` | `n8n_main_*`/`n8n_worker_*`/`n8n_webhook_*` CPU/memory request/limit inputs | |
| `nodeSelector` | Not surfaced | No caller need identified; node placement is via the module-managed node pool |
| `tolerations` | Not surfaced | Same as `nodeSelector` |
| `affinity` | Derived (`multiMain.antiAffinity`) only | No general pod affinity/anti-affinity escape hatch |
| `nodePlacement` | Not surfaced | |
| `securityContext` | Not surfaced (chart default retained) | The chart's own default pod/container security context is not currently overridden |
| `rbac` | Not surfaced | Chart defaults retained |
| `serviceAccount` | `n8n_image_pull_secrets` (indirectly, via ownership transfer) | The module takes over `serviceAccount.create`/`name` only when pull secrets are set; otherwise the chart's own default account is used |
| `networkPolicy` | Not surfaced | No `NetworkPolicy` resource is created by this module |
| `probes` | Not surfaced (chart defaults retained) | |
| `lifecycle` | `n8n_termination_grace_period` (main preStop only) | |
| `hpa` | `n8n_main_hpa_*`, standalone webhook HPA | |
| `keda` | `n8n_worker_keda_enabled`, worker KEDA tuning inputs, `n8n_worker_keda_pause`/`n8n_worker_keda_paused_replica_count` | `keda.webhookProcessor.*` (including its `pause`) is not surfaced: webhook processors are scaled by the module's own external HPA (`scaling.tf`), so no chart `ScaledObject` exists for it |
| `pdb` | Derived (`local.n8n_main_pdb_min_available`) | Always enabled; `minAvailable` is 0 for single-main, 1 otherwise |
| `webhook` | See `webhookProcessor` | The chart's top-level `webhook` values namespace (as distinct from `webhookProcessor`) is not separately surfaced; verify against the pinned chart's schema before assuming they are the same key |
| `executions` | `n8n_execution_timeout`, `n8n_execution_timeout_max`, `n8n_execution_concurrency_limit`, `n8n_executions_data_save_*` | |
| `config` | `n8n_timezone`, `n8n_extra_env`, and the module's large set of dedicated `N8N_*`/`DB_*`/`QUEUE_*` inputs (via `config.extraEnv`) | Most application-level tuning flows through here as environment variables, not chart-native config keys |
| `license` | `n8n_license_key`, `n8n_license_key_secret_ref` | |
| `secretRefs` | Derived (`local.effective_core_secret_name`) | |
| `database` | `postgres_*` inputs, `n8n_database_*` external-database inputs | |
| `redis` | `redis_*` inputs, KEDA/queue wiring, `n8n_queue_worker_lock_duration`/`n8n_queue_worker_lock_renew_time`/`n8n_queue_worker_stalled_interval`/`n8n_graceful_shutdown_timeout` (`redis.worker.*`) | `redis.worker.maxStalledCount` is not surfaced |
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
