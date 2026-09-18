## Context

See `proposal.md` for scope and `parity-matrix.md` for the source-backed disposition of AWS functionality. This design targets the Google baseline and chart 1.10.1, not AWS resource names or chart 1.10.0 assumptions.

The module already supports independent infrastructure, namespace, ingress, controller, and scaler ownership. Terraform 1.9.8 is the CI floor. Mocked `helm_release.values` is often unknown because the release depends on the namespace and managed services. Tests must not use mock apply as a workaround.

## Goals and non-goals

- Add missing behavior through typed inputs and the existing effective-coordinate locals. Avoid new submodules or a general-purpose Helm-values escape hatch.
- Keep current defaults unless a specific requirement below changes them. Permission to break compatibility is not a reason to rename the Google interface or reset tuning to AWS values.
- Keep raw secrets out of Helm values where this change supplies reference-based alternatives. Direct credential inputs still enter Terraform state.
- Do not install monitoring stacks, invent Google maintenance semantics, fork the chart, change cloud engine majors, or claim load-tested Google sizing.
- No live apply is needed for implementation acceptance. Document runtime verification separately and mark it not run unless an operator actually performs it.

## Decisions

### 1. Test the chart paths that production uses

Factor only the relevant input-derived value fragments into locals consumed by `helm_release.n8n`: topology, runtime settings, DNS, execution-save settings, queue tuning, and caller mount definitions. Keep resource-derived credential coordinates in the existing effective locals. Do not expose secret-bearing full Helm values as an output or introduce a new module for testability.

Add a script under `tests/scripts/` that renders chart 1.10.1 with these same fragments and synthetic resource/Secret coordinates. Obtain pure values using an isolated Terraform console state or an equivalent credential-free fixture. Assert rendered Kubernetes objects independently of the implementation expressions. Do not duplicate the production formulas in the fixture.

Cover all three n8n roles and both main/worker sidecars. Assert individual names/keys, selectors, volume mounts, and environment values, not merely that rendering exits zero. Verify that the release consumes the tested fragments in code review and keep plan assertions for the input/resource contracts. Document the boundary: rendering is not a live Helm upgrade or a proof of runtime behavior.

A reviewed chart contract already establishes:

- Execution retention is `executions.data`, not `config.data`.
- Main-only strategy is top-level `strategy`; it does not alter worker/webhook deployments.
- `multiMain.enabled=false`, `multiMain.replicas=1`, and `replicaCount=1` render successfully. The minimum-two schema restriction is conditional on multi-main.
- `service.annotations` reaches both main and webhook Services. Do not introduce an out-of-band annotation patch to fix an unproven chart omission.
- Deployment replicas are unconditional. This plan preserves floor seeding, not complete protection from upgrade replica resets.

### 2. Derive topology from the selected replica contract

Compute the effective initial main count from HPA minimum when `n8n_main_hpa_enabled=true`, otherwise from `n8n_main_fixed_replicas`. Count 1 selects single-main; counts above 1 select multi-main. This extends AWS behavior to Google's existing independent scaler ownership.

For single-main, render `multiMain.enabled=false`, `replicaCount=1`, main `strategy={type="Recreate", rollingUpdate=null}`, and main PDB `minAvailable=0`. A module-owned main HPA is 1/1 regardless of a higher configured maximum. With HPA ownership disabled, render no main HPA and one fixed main. Document that an external scaler must not exceed one until the operator switches topology with the appropriate entitlement.

For multi-main, retain the current chart strategy, PDB minimum 1, and configured bounds. Share the effective maximum with `capacity.tf`, including runner requests on actual main/worker counts. Add the optional exporter's fixed CPU/memory requests to the managed estimate. No verdict for customer-managed GKE.

Validate whole-number replica counts, positive bounds, minimum no greater than maximum, positive worker concurrency and scaler thresholds, and valid GKE per-zone bounds. Single-main clamping does not make an invalid maximum of zero acceptable. Validate CPU/memory strings against the quantity grammar actually supported by the existing capacity parser, with errors instead of `tonumber` failures. Keep replica and ownership inputs non-null. Add `n8n_webhook_hpa_scale_up_stabilization_window_seconds`, whole seconds 0 to 3600, default 0, to the existing standalone HPA.

Business single-main removes the multi-main entitlement requirement only. It does not grant External Secrets, log streaming, custom package registry, or object-storage entitlements. Do not parse license contents or claim that any Business key supports all enabled features. Recreate does not guarantee at-most-one execution after manual deletion, partition, or node failure.

### 3. Add runtime settings without competing environment sources

New names follow the existing Google application's `db_postgresdb_*` and `n8n_*` conventions. Do not rename existing inputs to AWS equivalents.

| Inputs | Defaults | Wiring and validation |
| --- | --- | --- |
| `db_ping_timeout_ms`, `db_ping_interval_seconds` | null | Positive whole milliseconds/seconds; emit `DB_PING_TIMEOUT_MS` and `DB_PING_INTERVAL_SECONDS` only when set. |
| `db_ping_max_failures_before_recovery` | null | Positive whole count; `DB_PING_MAX_FAILURES_BEFORE_RECOVERY`. |
| `db_postgresdb_connection_timeout_ms` | null | Whole milliseconds 0 to 2147483647; `DB_POSTGRESDB_CONNECTION_TIMEOUT`. Zero disables this acquisition timeout. |
| `n8n_queue_worker_lock_duration`, `n8n_queue_worker_lock_renew_time`, `n8n_queue_worker_stalled_interval` | null | Whole milliseconds at least 1000, using `redis.worker.lockDuration`, `lockRenewTime`, `stalledInterval`. Effective renewal must be less than duration, including chart defaults 10000/60000. Build one nested worker map so shallow merges cannot discard siblings. |
| `n8n_executions_data_save_on_success`, `n8n_executions_data_save_on_error` | `all`, `all` | Enum `all`/`none`, through `executions.data.saveOnSuccess`/`saveOnError`. |
| `n8n_executions_data_save_on_progress`, `n8n_executions_data_save_manual_executions` | false, true | Non-null booleans, through `executions.data.saveOnProgress`/`saveManualExecutions`. |
| `n8n_task_runner_timeout` | 300 | Positive whole seconds; `N8N_RUNNERS_TASK_TIMEOUT`. Document the deliberate pin and its difference from acceptance timeout. |
| `n8n_community_packages_registry` | null | Nonblank registry URL, HTTPS for a custom remote registry; `N8N_COMMUNITY_PACKAGES_REGISTRY`. Authentication is not embedded in this URL. |
| `n8n_unverified_packages_enabled` | null | Optional boolean; `N8N_UNVERIFIED_PACKAGES_ENABLED`. |
| `n8n_compression_max_decompressed_size_bytes`, `n8n_compression_max_zip_entries` | null | Positive whole quantities; `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` and `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES`. |
| `n8n_node_max_old_space_size_mb` | null | Whole MiB at least 256; global `NODE_OPTIONS=--max-old-space-size=<value>`. No runner heap change. |

All optional values omit their setting when null. Database and queue settings apply regardless of infrastructure ownership. Do not add a `QUEUE_WORKER_MAX_STALLED_COUNT` setting ignored by n8n v2, or bypass chart schema to allow stalled interval zero.

Reserve newly owned runtime names. Reserve `NODE_OPTIONS` only while the heap input is set; otherwise keep the existing escape hatch. Document that one heap value applies to all n8n containers and needs non-heap headroom beneath the smallest container limit. Do not impose AWS's 4 GiB example assumption on Google's 1 GiB webhook default.

### 4. Reference caller files and preserve Google-owned mounts

Add `n8n_extra_volumes` and `n8n_extra_volume_mounts`, both non-null lists defaulting to empty. A volume has `name` and exactly one typed source: `config_map`, `secret`, or `persistent_volume_claim`. ConfigMap/Secret sources accept name, optional item mappings, and optional permission mode as an octal string; convert it to the Kubernetes integer representation. A mount has name, canonical absolute `mount_path`, optional `sub_path`, and `read_only` defaulting to true. No `hostPath`, arbitrary YAML, PVC provisioning, or shared execution filesystem.

Validate names, uniqueness, mount references, item paths, and protected-path overlap in both directions. Reserve chart/internal volume names `data`, `task-runner-config`, and `redis-ca`; protect `/home/node/.n8n`, `/etc/n8n-certs`, and the runner configuration mount. Merge caller mounts with managed Redis CA mounts rather than replacing them. Accept an extension path backed by either a custom image or a covering caller mount, with a warning if neither provides files. Document multi-pod PVC access requirements.

Add `n8n_task_runner_custom_config = {config_map_name, config_map_key = optional(string, "n8n-task-runners.json")}`, default null. Validate DNS-1123 ConfigMap names and Kubernetes key rules separately; require enabled task runners. Wire `taskRunners.customConfig` for the main/worker sidecars only. Do not read the file or generate permissive JavaScript/Python allow-lists. The caller must derive the whole configuration from the exact runner image and restart both deployments after a ConfigMap change.

Add `n8n_dns_config`, default null, with optional nameservers, searches, and `{name,value?}` options. Validate at most three IP nameservers, Kubernetes search count/length bounds, unique options, and `ndots` from 0 to 15. Use conservative DNS search-name validation compatible with supported GKE releases, rather than silently depending on a newer relaxed validation gate. Emit only non-null members. Keep cluster DNS policy and resolver deployment unchanged.

### 5. Separate key continuity, license delivery, and credential overwrites

Add sensitive `n8n_encryption_key`, default null, accepting the existing generated-key format of 64 hexadecimal characters. Reject simultaneous `existing_n8n_core_secret_name`. When direct, use the supplied value in the managed core Secret and generate no replacement key. When neither is set, keep generation. The sensitive output returns the generated/direct value and remains null for an unread external core Secret. Update restore diagnostics to recognize either continuity path. This is key reuse, not rotation or proof that the key matches the database.

For direct `n8n_license_key`, create a dedicated module-managed license Secret and reference it through `license.existingSecret` on all three roles. Omit the literal activation key. Preserve the separate-license-reference requirement when the caller supplies an entire core Secret. Do not change existing external DB, Redis, or GCS Secret ownership.

Add `n8n_credentials_overwrite_secret_ref={name,key}`, default null. Mount only the selected key at `/etc/n8n/credentials-overwrite/overwrites.json`, read-only, and set `CREDENTIALS_OVERWRITE_DATA_FILE` on every n8n role. While enabled, reserve both overwrite environment names, the `credentials-overwrite` volume name, and any overlapping mount path. When null, preserve existing extra-env escape-hatch use. Never read/hash the Secret or copy its JSON into state, Helm values, or another Secret. Rotations require deliberate restarts; missing names/keys fail at runtime, not through a Secret lookup during plan.

### 6. Make Redis consumers share one namespace and TLS contract

When `redis_key_prefix` is set, add `N8N_REDIS_KEY_PREFIX` alongside chart `redis.prefix`. With null, omit both overrides so n8n retains command prefix `n8n` and Bull prefix `bull`. Derive waiting/active list names once for KEDA and the exporter. Reserve `N8N_REDIS_KEY_PREFIX` against conflicting extra environment values. A prefix correction on a running shared deployment is disruptive: drain and restart all roles together.

Add `redis_exporter_enabled=false` and `redis_exporter_image="oliver006/redis_exporter:v1.90.0"`, matching the verified AWS tag's image, not an unpinned latest image. In new `observability.tf`, create a single-replica Recreate Deployment and ClusterIP Service on 9121. Reuse effective Redis host/port, TLS flag, ACL username, and password Secret coordinates. Use explicit waiting/active key checks, not keyspace scanning. Add pod scrape annotations, resource requests/limits, probes, non-root execution, dropped capabilities, read-only filesystem, and no API token mounting. No n8n Workload Identity grant is needed for this Redis-only workload.

For managed Memorystore TLS, mount the existing service CA Secret and set `REDIS_EXPORTER_TLS_CA_CERT_FILE`. The exporter must verify the certificate against the effective address; never copy AWS's assumption that the public image trust store is sufficient. External Redis uses system trust and its certificate-matching host, consistent with the existing external connection contract. Private external CA, mTLS, and friendly-CNAME server-name overrides remain outside this change rather than silently disabling verification. The [exporter v1.90.0 documentation](https://github.com/oliver006/redis_exporter/blob/v1.90.0/README.md) verifies the CA setting. Runtime trust is on the manual checklist, not claimed by mocks.

Gate both exporter resources on its own switch, independent of `n8n_metrics_enabled`, KEDA installation, and scaler ownership. Add namespace/node readiness dependencies and retain password/CA resources when another Redis consumer needs them. Expose a nullable `redis_exporter_service_name` for caller scrape configuration.

### 7. Distinguish canonical URLs, aliases, and private routing

Use one effective webhook base URL: explicit `n8n_webhook_url`, otherwise `https://<n8n_fqdn>`. Emit `WEBHOOK_URL` and `N8N_WEBHOOK_URL` from it and `N8N_EDITOR_BASE_URL=https://<n8n_fqdn>`. Validate the webhook value as an HTTPS base URL without embedded credentials, query, or fragment. Reserve the current webhook environment name as well as the existing names.

Add `n8n_additional_domains=[]`: normalize lowercase, reject malformed/wildcard names, duplicates, and the canonical hostname. Under managed ingress, every host gets the full route set. Share the host list across ManagedCertificate domains, self-signed SANs, and TLS Secret host declarations. Add Cloud DNS records for aliases using stable hostname keys; retain the canonical record's current address to avoid unnecessary migration. One configured Cloud DNS zone must cover all records it manages; cross-zone callers manage DNS themselves. Cap Google-managed certificate domains at 100 including the canonical host. For custom PEM/Secret TLS, document that callers supply certificates covering every hostname; do not pretend to inspect external Secret certificates.

With `create_ingress=false`, aliases create no module DNS, address, certificate, or ingress resources. Expose the effective host list through `n8n_ingress_hosts` for callers. This intentionally differs from AWS's certificate ownership behavior.

Add `ingress_annotations={}`. Permit non-conflicting annotations only; protect module-owned ingress class, static IP, certificate, and FrontendConfig keys. Warn for nonempty annotations with managed ingress disabled. Dedicated inputs remain authoritative for security and ownership.

Create `examples/split-ingress` using the module with managed ingress disabled. The example owns public webhook routing and an internal HTTPS editor ingress. Follow [GKE internal ingress requirements](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress): regional internal IP, proxy-only subnet, proxy firewall access, `gce-internal`, and caller TLS Secret or supported regional certificate. Use explicit separate caller-owned Services and BackendConfigs for the two exposure boundaries; match their selectors against the pinned chart in rendering tests rather than patching Helm-owned Services. Public routes include the five webhook families and no main-service catch-all. Internal routing includes those families and the main catch-all. Use module route/port outputs; output the addresses and DNS instructions. Do not use the global external ManagedCertificate/FrontendConfig contract on the internal ingress. The caller provides private DNS reachability and TLS material; no VPN or certificate-manager installation is added.

### 8. Adapt data-service operations rather than copying AWS APIs

Add nullable `postgres_backup_retained_backups` (whole 1 to 365) and `postgres_transaction_log_retention_days` (whole 1 to 7 for ENTERPRISE, 1 to 35 for ENTERPRISE_PLUS). Wire the documented backup retention/count and transaction-log fields only when supplied. Keep backups and PITR enabled. Optional values preserve the provider's existing defaults. Add `postgres_query_logging_enabled=false`; when true, use PostgreSQL DDL and 1000 ms slow-statement logging flags, not all-query logging or `rds.force_ssl`. Include potential query-text exposure in documentation. All three settings warn as ignored for external PostgreSQL.

Add `redis_persistence_enabled=false`, `redis_rdb_snapshot_period="TWENTY_FOUR_HOURS"`, and nullable `redis_rdb_snapshot_start_time`. Use Memorystore `persistence_config` with `RDB` only on the managed enabled path; accept the four documented period enums and RFC3339 start times. Warn for ignored tuning on disabled persistence or external Redis. Treat RDB as last-snapshot automatic recovery, not historical backup retention. Document snapshot memory overhead, latency, and loss/replay risk before recommending opt-in. Keep independent export/import backups as an operator responsibility.

No `apply_immediately`, generic maintenance switch, automatic major-version bump, or `ignore_changes` on PostgreSQL version is added. Those would obscure rather than translate Google behavior.

### 9. Make verification enforceable without a live cluster

Keep Terraform 1.9.8 validation and mock tests for the root, all application examples, controller submodule, and direct controller example. Extend every relevant CI job for split ingress. Pin rendering/security tools and use the same commands locally and in CI. Tests for plan-unknown wiring must name what the render check proves and what remains manual.

Inventory Checkov findings before changing its failure mode. Fix genuine findings; use narrowly scoped, explained exceptions only where the selected Google feature contract makes a finding intentional or false. Do not suppress an entire check globally because one optional resource triggers it. Add structural tests for exporter hardening because Checkov may not inspect version-suffixed Kubernetes resources. Flip `soft_fail` only after the reviewed baseline passes and demonstrate that a new unapproved violation fails. Do not silently change unrelated defaults to satisfy a scanner; any necessary security behavior change must be explicit in the changelog and plan review.

## Risks and mitigations

- Single-main maintenance interrupts editor, REST API, and scheduled triggers. Document maintenance windows and test main-only strategy/PDB/HPA behavior.
- A secret delivered by reference is not validated for existence or correctness at plan time. Keep state free of its contents and provide runtime diagnostics.
- New reserved names break previously accepted escape-hatch configurations. Provide an environment-name-to-input migration table before release.
- Redis prefix changes and recovered snapshots can strand or replay jobs. Require queue drain and application-aware recovery in the runbook.
- Aliases and split ingress affect DNS, certificate coverage, OAuth callbacks, and public exposure. Test route allow-lists and keep internal/public resources separate.
- Snapshotting, query logging, and tuning can harm performance. Keep them opt-in and retain unmeasured Google sizing labels.
- Chart rendering and mocks cannot verify Google TLS handshakes, GKE controller reconciliation, licensing, or upgrades. Explicitly record these as manual and not run.

## Migration plan

1. Publish a change-specific compatibility table: new inputs, newly reserved names, runtime defaults, URL/prefix corrections, and any actual resource address changes. No automatic state migration is promised by this pre-release module.
2. Before applying, back up Terraform state, the exact encryption key, the database, and binary data. Record current hostnames, license sources, image/chart versions, and selected ownership paths.
3. Migrate extra-env settings to dedicated inputs. Supply the original encryption key or existing core Secret for restore. Do not regenerate or rotate it as an upgrade step.
4. Inspect the plan for replacements, certificate changes, new license Secret delivery, and topology changes. Schedule single-main transitions and coordinated Redis changes; drain queues where required.
5. Follow the manual checklist after an operator-approved apply. Implementation completion only requires the automated suite and delivery of that checklist.
6. For rollback, return to the previous configuration/module revision only after checking state addresses and credential sources. Restore matching state/resource references deliberately; never blindly push old state over changed infrastructure. Restore the same encryption key, and avoid rolling back a Redis namespace with undrained work. Database engine rollback is not part of this change.
