# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md, Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

> **No automatic state migration.** This module is pre-release (no tagged
> version has shipped this interface yet), so every breaking rename, removed
> input/output, and resource-address change below ships with no `moved` block
> and no migration path: adopting this interface on top of a prior `apply`
> requires either a fresh `terraform apply` against a new state, or manually
> reconciling resource addresses and renamed inputs/outputs yourself. This is
> intentional while the module has no stable release to preserve compatibility
> with; see [README.md, Stability & versioning](./README.md#stability--versioning).

### Added
- `CONTRIBUTORS`, `Taskfile.yml`, and `scripts/check-variable-banners.sh`,
  mirroring the CODEOWNERS/CONTRIBUTORS/Taskfile convention introduced in
  terraform-aws-n8n's [#82](https://github.com/n8n-io/terraform-aws-n8n/pull/82).
  `Taskfile.yml` wraps the local fmt/validate/test/chart/chart-coverage/
  lint/banners/example-parity/docs/markdown loop (`task ci`) across the
  module root, every example, and the `modules/controllers` submodule;
  `checkov` and `version-drift` are separate tasks not part of `task ci`.
  `check-variable-banners.sh` (`task banners`) verifies every
  `variable`/`output` block in `variables.tf`, `variables_gcp.tf`, and
  `outputs.tf` sits under its documented `# ── Section ──` banner.
  `.github/CODEOWNERS` gained an explanatory header comment. Fixed one
  pre-existing gap the new banner check surfaced: `variables_gcp.tf`'s
  `project_id`/`gcp_region` had no banner; added a `Project and region`
  banner ahead of them.
- **Worker pools (EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE)**: `n8n_worker_pools`,
  `n8n_worker_extra_env`, and `n8n_worker_pools_chart_verified` inputs, ported
  1:1 from terraform-aws-n8n's own worker-pools feature (`worker-pools.tf`).
  Each `n8n_worker_pools` entry becomes one `queueMode.workerGroups` Helm
  value, rendering a labelled worker Deployment plus a KEDA `ScaledObject`
  watching that pool's own `jobs-<name>` queue, so executions pinned to a
  pool in the n8n UI (Project, Settings, Worker Pools) autoscale
  independently of the default worker's queue. Tracks two upstream features
  that are themselves alpha: n8n's own worker pools (needs n8n >= 2.39.0 and
  a license carrying `feat:workerPools`) and the chart support for them
  (`queueMode.workerGroups`, merged only to n8n-hosting's
  `preview/worker-pools` branch, not released to a numbered chart version).
  A `lifecycle.precondition` on `helm_release.n8n` fails the plan when
  `n8n_worker_pools` is non-empty and the pinned chart cannot be trusted to
  render it (a worker-pools preview build, a prerelease whose identifier
  contains `workerpools` such as `1.11.0-preview.workerpools.1`, passes
  automatically; any other version, numbered or generic prerelease, needs
  `n8n_worker_pools_chart_verified = true`), and
  `check.worker_pools_require_n8n_2_39` warns when `n8n_image_tag` predates
  the feature. `capacity.tf`'s node-capacity guardrail now folds each pool's
  own replica ceiling and resolved CPU/memory requests into the module's peak
  estimate. New `examples/worker-pools/` (3-pool topology: `heavy`,
  `secteam`, `itop`, mirroring terraform-aws-n8n's own example) and
  `tests/scripts/verify-worker-pools.sh` (post-apply verification; no
  released chart renders the feature, so nothing at plan time can prove it).
  Requires `n8n_worker_keda_enabled = true` (validated on `n8n_worker_pools`):
  the chart renders a pool's `ScaledObject` only under release-wide KEDA
  scaling and otherwise runs the pool at 1 replica, silently ignoring its
  replica bounds. A pool's triggers reference the same `n8n-redis-auth`
  `TriggerAuthentication` the default worker's do (managed Redis AUTH,
  username, and the Memorystore private CA on the
  `redis_transit_encryption_enabled = true` path) via the chart's
  `queueMode.workerGroups[].keda.authenticationRef`, verified against
  `1.11.0-preview.workerpools.1`, so pools and the default worker
  authenticate to Redis identically.

- **`n8n_worker_keda_pause` and `n8n_worker_keda_paused_replica_count`**
  (chart `keda.worker.pause` / `pausedReplicaCount`, n8n-hosting#177, shipped
  in chart 1.12.0; reliable from 1.13.0, see below). `pause = true` annotates the worker `ScaledObject` with
  `autoscaling.keda.sh/paused` so workers hold their current count; a
  `paused_replica_count` (0 included) adds `paused-replicas` and scales to
  that count while new jobs wait in Redis, e.g. before a migration. Scaling
  down stops running workers after n8n's graceful shutdown window, so let
  active executions finish before setting a lower count. A count set
  without `pause` draws a plan-time warning
  (`check.worker_keda_paused_replica_count_requires_pause`) since the chart
  ignores it. `check.worker_keda_pause_requires_a_supported_chart` warns when
  either input is set on a default-repository chart older than 1.13.0:
  charts before 1.12.0 ignore the key, and 1.12.0 re-renders the worker
  replica count on every Helm upgrade, overriding a held count. Only the
  default worker is paused; `n8n_worker_pools` pools are not. Same input
  names, semantics, and check names as terraform-aws-n8n. The chart's matching `keda.webhookProcessor.pause`
  is deliberately not exposed: this module scales webhook processors with its
  own HPA (`scaling.tf`), so no webhook `ScaledObject` exists for the
  annotation to land on. `tests/scripts/smoke-test.sh` skips the worker
  floor assertion, the queue workflow run, the load test, and (with no
  running worker) the worker Redis probe while the `ScaledObject` is paused. Live-verified
  2026-09-23 on a fresh scratch `examples/small` at chart `1.13.0`: paused
  with `n8n_worker_keda_paused_replica_count = 0` scaled the worker
  Deployment `2 -> 0` inside the same `terraform apply` (no separate KEDA
  reconcile needed to reach zero), `ScaledObject` reported `PAUSED=True`
  with both annotations set; clearing the pause resumed `0 -> 2` in the
  next apply (49s to `2/2` ready) and `ScaledObject` returned to
  `PAUSED=False` with the annotations removed; `smoke-test.sh` (multi-main)
  passed 33/34, the one miss unrelated to this change (a transient
  `/healthz` timing check), with the worker sidecar, launcher-config
  volume, and KEDA `ScaledObject` checks all correctly pointed at the
  worker pod.

- `docs/versioning.md`: the full inventory of every version this module
  pins (providers, the n8n and KEDA Helm charts, `postgres_version`, the
  GKE release channel, and the CI toolchain), which file it lives in, and
  which of three bump tiers it falls into (patch-safe, minor-required,
  verification-required). Linked from `AGENTS.md`, `README.md`'s
  Compatibility section, and `docs/upgrading-n8n.md`.
- `tests/scripts/check-version-drift.sh` and a weekly
  `.github/workflows/version-drift.yml` job: reports every pin reachable
  from a public API (Terraform providers via the registry API, the n8n
  chart via GHCR's anonymous tag listing, and the KEDA chart via its Helm
  repo) that has fallen behind upstream, and files/updates a single
  tracking issue. Reports only, never auto-bumps or fails a build; every
  lookup failure is reported as an explicit error distinct from "no drift
  found".
- `docs/helm-chart-coverage.md` and `tests/scripts/check-helm-chart-coverage.sh`:
  fails when the doc's declared chart version disagrees with
  `n8n_chart_version`'s default, or when the pinned chart's `values.yaml`
  gains a top-level key the doc never mentions.
- `tests/scripts/chart-values-diff.sh` (`tests/scripts/chart-values-diff.sh <candidate-version>`):
  diffs the pinned n8n chart's `values.yaml` against a candidate version
  via `helm show values`, so the manual diff step of a chart-version pickup
  is one command. Never writes or bumps a pin. The shared "read a variable
  default out of `variables.tf`" helper these three scripts and
  `tests/scripts/check-checkov.sh` need now lives once in
  `tests/scripts/lib/tf-defaults.sh`.
- **`docs/istio-ingress.md`**: routing knowledge for a caller running Istio
  instead of a GKE Ingress Controller. Covers the same `create_ingress =
  false` contract and route-prefix ordering `examples/split-ingress`
  documents for the GKE-native case, expressed as `Gateway`/`VirtualService`
  instead of `kubernetes_ingress_v1`, and the "200 with an HTML body"
  webhook-misroute trap both share. Purely additive: no new example, no new
  module input or output.
- `markdownlint` CI job (`markdownlint-cli2`) linting `README.md`,
  `AGENTS.md`, and `docs/*.md`. `README.md`'s generated
  `<!-- BEGIN_TF_DOCS -->` block is wrapped in
  `<!-- markdownlint-disable -->`/`<!-- markdownlint-restore -->` comments
  (placed outside the block) so its anchor tags and placeholder tokens
  don't need hand-editing to pass. `.markdownlint.json` disables MD013
  (line-length), MD036 (emphasis-as-heading, `docs/troubleshooting.md`'s
  deliberate Symptom/Cause/Fix convention), MD040 (fenced-code-language),
  and MD060 (table-column-style, a rule new enough that none of this
  repo's existing tables were written against it).
- The root `terraform test` CI job is split one job per `tests/*.tftest.hcl`
  file (`test-root`, matrix generated from the filesystem so a new file is
  never skipped), runs without `-verbose`, and every test job carries a
  `timeout-minutes`. One serial job with full plan output for 500 runs took
  43 minutes and starved the runner until a mock provider missed Terraform's
  60 s plugin start timeout, failing an unrelated run.
- A second, opt-in checkov pass (`checkov-opt-in` CI job,
  `tests/scripts/check-checkov.sh`) against a new
  `tests/checkov/opt-in.tfvars` fixture that flips on every switch gating a
  resource that defaults to count 0. checkov answers every check on a
  count-0 resource `UNKNOWN`, not `FAILED`, and drops it from the report
  entirely, so the opt-in `redis_exporter` Deployment's `CKV_K8S_*` checks
  had never actually run against a real resource. The script additionally
  verifies the opt-in pass reached every resource in its own
  `REQUIRED_OPT_IN_RESOURCES` list, not just that the run exited 0.
  `terraform test` gained assertions pinning the exporter's security
  context, capabilities, memory limit, image digest, and probes, and a
  narrowly scoped `checkov:skip=CKV_K8S_11` (no CPU limit) records the
  already-deliberate trade the resource's own comment explains.
- `scripts/check-example-parity.sh` (local-only for now, not yet wired into
  CI): diffs the variable-name set every `examples/*/variables.tf` declares
  against `examples/small`'s and fails on any name present on only one side
  that is not in that example's own allowlist. Also fails when an example
  still lets the module create Cloud SQL or GCS but its README has no
  "Production considerations" section.
- A "Production considerations" README section on every example that lets
  the module own Cloud SQL and/or GCS (`small`, `medium`, `large`,
  `cloudflare`, `godaddy`, `split-ingress`, `customer-managed-redis`,
  `customer-managed-cluster`, `customer-managed-gcs`), naming
  `postgres_deletion_protection`, `postgres_backup_retained_backups`,
  `postgres_transaction_log_retention_days`, and `gcs_force_destroy` as the
  caller-facing knobs and linking `docs/destroy-cleanup.md`.
  `postgres_backup_retained_backups`/`postgres_transaction_log_retention_days`
  (previously module-only) are now passed through by every example above,
  and `n8n_additional_domains` (previously passed through by no example) by
  `small`, `medium`, `large`, `customer-managed-cluster`,
  `customer-managed-redis`, `customer-managed-gcs`, and
  `customer-managed-everything`. `examples/cloudflare/README.md` and
  `examples/godaddy/README.md` now explain why neither takes
  `n8n_additional_domains`: each issues its own single-hostname
  certificate/DNS record and the module cannot add Subject Alternative
  Names to a certificate it did not itself issue.
- Every example now exposes the ownership-neutral outputs
  `tests/scripts/smoke-test.sh` reads from `terraform output` in the example
  directory (`redis_host`, `redis_tls_enabled`, `redis_exporter_service_name`,
  `gcs_bucket_name`, `n8n_main_service_name`, `n8n_webhook_service_name`,
  `n8n_service_port`, `n8n_webhook_route_prefixes`, `n8n_ingress_hosts`).
  A live `examples/small` run on 2026-09-18 showed the smoke test's Redis,
  GCS, ingress-route, and additional-hostname checks silently skipped
  because the example roots did not pass these through.
- `examples/small`, `examples/medium`, and `examples/large` accept
  `n8n_image_tag` (default `null`) so a caller can pin the n8n version
  without editing `main.tf`; `terraform.tfvars.example` shows the pin. The
  chart's floating `stable` tag remains the default.
- Added `psa_connection_abandon_on_destroy` (default `true`) so callers can
  choose how the module-managed Private Services Access connection is torn
  down. `true` keeps `deletion_policy = "ABANDON"`; `false` leaves the policy
  unset so the provider attempts the servicenetworking API delete, which may
  stall on GCP's producer-in-use check. Ignored when `create_psa = false`.
  Changing it requires a `terraform apply` before the next `destroy` so the
  policy is recorded in state. Plan-time coverage in
  `tests/network_ownership.tftest.hcl`.
- Added nullable `n8n_main_leader_election_enabled` for explicit two-stage
  single-main to multi-main conversion. Enable election at one replica first,
  retaining Recreate, PDB minimum 0, and managed HPA maximum 1; verify the old
  election-disabled process has exited before separately increasing replicas.
  Null preserves existing count-based defaults; false is rejected above one
  selected replica. This supports a staged procedure, not automatic ordering:
  an un-staged replica increase can still scale the old single-main revision.
  Added plan/render coverage and an operator verification procedure. The
  two-stage procedure was run live with an idle workload on both the managed
  HPA and fixed-replica paths (see `docs/manual-verification-checklist.md`);
  the active-schedule regression remains incomplete.
- Added `n8n_additional_domains` and `ingress_annotations`
  (`add-google-parity-through-aws-0-4-0`, section 20.1): `n8n_additional_domains`
  (default `[]`) declares extra hostnames that will get the full main/webhook
  route set alongside `n8n_fqdn`; entries are validated as non-wildcard FQDNs,
  rejected on a case-insensitive duplicate or a repeat of `n8n_fqdn`, and
  exposed (lowercase-normalized, canonical host first) through the new
  `n8n_ingress_hosts` output regardless of `create_ingress`, so a
  customer-managed ingress can consume the same list. Wiring these hostnames
  into the module-managed Ingress, Cloud DNS records, and TLS certificate
  coverage lands in a following section; today the input only validates and
  reports the effective list. `ingress_annotations` (default `{}`) accepts
  additional annotations for the module-managed Ingress, rejecting any
  module-owned key (ingress class, static-IP name, FrontendConfig,
  ManagedCertificate, or pre-shared-cert) and warning as ignored when
  `create_ingress = false`.
- Wired `n8n_additional_domains` and `ingress_annotations` into the
  module-managed Ingress, Cloud DNS records, and TLS certificate coverage
  (`add-google-parity-through-aws-0-4-0`, section 20.2): every hostname in the
  effective `n8n_ingress_hosts` list (canonical `n8n_fqdn` plus every
  `n8n_additional_domains` entry) now gets its own Ingress `rule` with the
  identical webhook/main route set, its own Cloud DNS A-record (when
  `cloud_dns_zone_name` is set), inclusion in the `google_managed`
  `ManagedCertificate`'s domain list (capped at 100 total, enforced by a new
  `n8n_additional_domains` validation), and inclusion in the `self_signed`
  certificate's SANs and the `secret` mode's `spec.tls.hosts`. `custom`/
  `secret` TLS coverage of every hostname remains a caller prerequisite; the
  module does not inspect an external Secret's certificate. Non-conflicting
  `ingress_annotations` entries are now merged onto the managed Ingress's
  metadata. The Cloud DNS record resource moved from `count` to `for_each`
  keyed by hostname so the canonical record keeps a stable per-hostname
  address as aliases are added or removed; per this module's pre-release "no
  automatic state migration" policy above, an existing deployment upgrading
  onto this resource address change needs a manual `terraform state mv
  'google_dns_record_set.n8n[0]' 'google_dns_record_set.n8n["<n8n_fqdn
  value>"]'` before applying (documented in `docs/upgrading-n8n.md`).
  Canonical `n8n_url`/`N8N_EDITOR_BASE_URL`/effective webhook URL outputs are
  unaffected by aliases.
- Documented the DNS-zone and caller-certificate prerequisites for
  `n8n_additional_domains` (`add-google-parity-through-aws-0-4-0`, section
  20.3): `cloud_dns_zone_name` is a single zone that must cover every
  hostname the module creates a record for; an alias delegated to a different
  zone or DNS provider is the caller's responsibility. `tls_cert_pem`/
  `tls_secret_name` (custom/secret `tls_mode`) must already cover every
  hostname in `n8n_ingress_hosts`; the module does not read or parse an
  external Secret's certificate to confirm that coverage, so a mismatch
  surfaces as a TLS handshake failure, not a Terraform-time error.
- **Breaking:** every n8n role now emits `N8N_EDITOR_BASE_URL=https://<n8n_fqdn>`
  (`add-google-parity-through-aws-0-4-0`, section 19): this environment name
  was previously reserved (see `n8n_extra_env`'s collision guard) but never
  actually set, leaving n8n to compute its own editor/OAuth base URL
  internally. If any OAuth2 credential's redirect URI was registered against
  that computed URL rather than `https://<n8n_fqdn>/rest/oauth2-credential/callback`,
  re-register it with the provider using the callback host `n8n_fqdn` resolves
  to. `n8n_webhook_url` (default `https://<n8n_fqdn>`) is now also emitted
  under n8n's current `N8N_WEBHOOK_URL` name in addition to the legacy
  `WEBHOOK_URL` name, both sourced from one effective value so the two can no
  longer drift apart; `n8n_webhook_url` now validates as an `https://` base
  URL with no embedded userinfo credentials, query string, or fragment.
- Added `redis_persistence_enabled`, `redis_rdb_snapshot_period`, and
  `redis_rdb_snapshot_start_time` (`add-google-parity-through-aws-0-4-0`,
  section 18): opt-in Memorystore RDB persistence
  (`persistence_config.persistence_mode = RDB`) on the module-managed
  instance, defaulting to disabled. When enabled, `redis_rdb_snapshot_period`
  selects one of Memorystore's own `ONE_HOUR`, `SIX_HOURS`, `TWELVE_HOURS`, or
  `TWENTY_FOUR_HOURS` schedules (default `TWENTY_FOUR_HOURS`), and
  `redis_rdb_snapshot_start_time` optionally pins an RFC3339 alignment
  timestamp. This is Memorystore's automatic last-snapshot recovery on an
  unplanned restart, not a numbered backup-retention count like Cloud SQL's
  `postgres_backup_retained_backups` or AWS ElastiCache snapshots: at most one
  RDB snapshot is kept and replayed, which can reintroduce stale/duplicate
  queue jobs and adds memory and latency overhead while a snapshot is being
  written. All three inputs are ignored (with an opposite-path warning) for
  external Redis, and the two schedule inputs are separately warned when set
  while persistence is disabled. Independent export/import backups remain an
  operator responsibility; this module does not schedule or manage them.
- Added `postgres_backup_retained_backups`, `postgres_transaction_log_retention_days`,
  and `postgres_query_logging_enabled` (`add-google-parity-through-aws-0-4-0`,
  section 17): optional managed Cloud SQL backup-count (COUNT retention, 1-365)
  and transaction-log retention (1-7 days for `ENTERPRISE`, 1-35 for
  `ENTERPRISE_PLUS`) tuning, using Cloud SQL's own retention semantics rather
  than AWS retention days. Backups and point-in-time recovery remain enabled
  unconditionally; both inputs default to `null` and preserve the provider's
  existing default retention when omitted. `postgres_query_logging_enabled`
  defaults to `false` and, when enabled, adds PostgreSQL `database_flags` for
  DDL logging (`log_statement=ddl`) and statements taking at least 1000 ms
  (`log_min_duration_statement=1000`), not all-statement logging; logged
  slow-statement text may include literal query parameter values. All three
  are ignored (with an opposite-path warning) for external PostgreSQL.
- Added `redis_exporter_enabled` and `redis_exporter_image`
  (`add-google-parity-through-aws-0-4-0`, section 16): an opt-in, private
  Redis exporter (`oliver006/redis_exporter`, pinned to `v1.90.0` by default)
  exposing Bull queue depth and other Redis metrics on a `ClusterIP` Service
  (port 9121), independent of `n8n_metrics_enabled` and worker KEDA. Off by
  default. The exporter reuses the same effective Redis host/port/TLS/ACL
  username/password Secret and exact waiting/active queue keys n8n and KEDA
  already use (`redis_key_prefix`-aware), trusts the module-managed
  Memorystore service CA when transit encryption is enabled, and never
  disables TLS verification. Runs as a single hardened, non-root Deployment
  (dropped capabilities, read-only root filesystem, no privilege escalation,
  no API token mount, resource requests/limits, liveness/readiness probes).
  Adds a new `redis_exporter_service_name` output (`null` when disabled) and
  folds the exporter's fixed CPU/memory requests into the managed GKE
  capacity guardrail (`capacity.tf`). Installs no Prometheus/Grafana
  resources.
- Added `n8n_community_packages_registry`, `n8n_unverified_packages_enabled`,
  `n8n_compression_max_decompressed_size_bytes`, and
  `n8n_compression_max_zip_entries` (`add-google-parity-through-aws-0-4-0`,
  section 15): optional registry/security runtime controls mapped to
  `N8N_COMMUNITY_PACKAGES_REGISTRY`, `N8N_UNVERIFIED_PACKAGES_ENABLED`,
  `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES`, and
  `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` on every n8n role (main, worker,
  webhook processor). All four default to `null`, which omits the
  corresponding env var and leaves n8n's own upstream default in place so a
  future n8n release can change it without this module pinning it.
  `n8n_community_packages_registry` must be a non-blank `https://` URL with
  no embedded userinfo credentials; this module has no separate mechanism
  for registry authentication, and the registry override does not by itself
  grant the separate Enterprise entitlement community package installation
  requires. The two compression limits must be positive whole numbers when
  set.
- Added `n8n_dns_config` (`add-google-parity-through-aws-0-4-0`, section 13):
  optional pod-level DNS settings (nameservers, search domains, and options
  such as `ndots`) applied to the main, worker, and webhook-processor pods
  via the chart's top-level `dnsConfig`. Defaults to `null`, which omits the
  block and leaves Kubernetes' cluster DNS defaults unchanged. Nameservers
  are capped at 3 plain IPv4/IPv6 addresses; search domains are validated
  against strict RFC 1123 subdomain rules (no underscores, no bare `"."` or
  trailing dot) rather than the relaxed rules Kubernetes only guarantees on
  1.34+, since this module targets GKE's supported release channels, which
  can run older control planes; option names must be unique, and `ndots`
  must be a whole number from 0 to 15.
- Added `n8n_task_runner_custom_config` and `n8n_task_runner_timeout`
  (`add-google-parity-through-aws-0-4-0`, section 12): reference an existing
  ConfigMap holding a custom task-runner launcher configuration file, mounted
  read-only at `/etc/n8n-task-runners.json` on the task-runner sidecar of
  every main and worker pod via the chart's `taskRunners.customConfig`. The
  module never reads the ConfigMap's contents; the whole file (not a merge)
  comes from the caller and must match the exact task-runner image/version in
  use. Requires `n8n_task_runners_enabled = true`; setting it with runners
  disabled fails validation. `n8n_task_runner_timeout` (default 300 seconds,
  wired to `N8N_RUNNERS_TASK_TIMEOUT`) separately bounds how long an accepted
  Code node task may run, distinct from the existing
  `n8n_task_runner_request_timeout` (how long n8n waits for a runner to
  accept a task in the first place). Changing only the ConfigMap's contents
  does not trigger an automatic rollout: restart the `n8n-main` and
  `n8n-worker` deployments to load new data, see
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#task-runner-custom-launcher-configuration-needs-a-matching-image-and-a-manual-restart).
- Added `n8n_credentials_overwrite_secret_ref`
  (`add-google-parity-through-aws-0-4-0`, section 11): reference an existing
  Kubernetes Secret holding a credential-overwrites JSON payload, mounted
  read-only at `/etc/n8n/credentials-overwrite/overwrites.json` on every n8n
  role (main, worker, webhook processor) with `CREDENTIALS_OVERWRITE_DATA_FILE`
  pointed at it. The module never reads, hashes, or copies the referenced
  Secret's contents; only the selected key is mounted. While set, the
  `credentials-overwrite` volume name, the mount path, and the
  `CREDENTIALS_OVERWRITE_DATA`/`CREDENTIALS_OVERWRITE_DATA_FILE` environment
  names are reserved against `n8n_extra_volumes`/`n8n_extra_volume_mounts`/
  `n8n_extra_env`; both remain usable as before when this input is left at
  its default `null`. Changing only the referenced Secret's contents does not
  trigger an automatic rollout: restart the `n8n-main`, `n8n-worker`, and
  `n8n-webhook-processor` deployments to load new data, see
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#credential-overwrite-secret-content-changes-need-a-manual-restart).
- Added `n8n_extra_volumes` and `n8n_extra_volume_mounts`
  (`add-google-parity-through-aws-0-4-0`, section 10): mount an existing
  ConfigMap, Secret, or PVC into every n8n role (main, worker, webhook
  processor) via the chart's `extraVolumes`/`extraVolumeMounts`, without the
  module creating or reading the referenced object. Each volume declares
  exactly one typed source; a Secret/ConfigMap `default_mode` is an octal
  permission string (e.g. `"0440"`), converted to the decimal value
  Kubernetes expects (288). Mounts are validated for a declared volume
  reference, name/path uniqueness, a canonical absolute `mount_path`, and no
  overlap with the module's own protected mounts (`/home/node/.n8n`,
  `/etc/n8n-certs`). Caller mounts coexist with the module's managed Redis CA
  mount rather than replacing it. `n8n_custom_extensions_path` no longer
  warns about a stock image when a caller-managed mount covers that exact
  path.
- Delivered direct `n8n_license_key` values through a dedicated
  module-managed `kubernetes_secret.n8n_license` Secret instead of a literal
  `license.activationKey` Helm value (`add-google-parity-through-aws-0-4-0`,
  section 9). Every n8n role now reads the license through
  `license.existingSecret`, whether the module manages the Secret (direct
  key) or the caller supplies `n8n_license_key_secret_ref` (unread,
  referenced as-is, no duplicate managed Secret). No functional or interface
  change for callers already using either input; only the rendered Helm
  values change (no literal key ever appears in them).
- Added sensitive `n8n_encryption_key` (`add-google-parity-through-aws-0-4-0`,
  section 8): reuse a known 64-hexadecimal-character encryption key instead of
  letting the module generate one, e.g. to keep decrypting credentials in a
  restored/cloned database. Mutually exclusive with
  `existing_n8n_core_secret_name`. When supplied, the managed core Secret
  carries the exact value and no `random_id.n8n_encryption_key` is generated;
  the `n8n_encryption_key` output returns the supplied/generated value and
  stays null for an unread external core Secret.
- Added the foundation of the explicit infrastructure/Kubernetes ownership
  model (`add-full-stack-modularity`, section 1): non-null `create_network`,
  `create_psa`, `create_gke`, `create_redis_instance`, `create_gcs_bucket`,
  `create_namespace`, `create_ingress`, `n8n_main_hpa_enabled`,
  `n8n_webhook_hpa_enabled`, and `n8n_worker_keda_enabled` switches; typed
  customer-managed references (`existing_network_name`,
  `existing_subnetwork_name`, `existing_pods_range_name`,
  `existing_services_range_name`, `existing_psa_prerequisites_attestation`,
  `existing_gke_cluster_name`, `existing_gke_prerequisites_attestation`,
  `existing_gke_workload_identity_pool`, `redis_host`/`redis_port`/
  `redis_tls_enabled`/`redis_username`/`redis_password`,
  `existing_gcs_bucket_name`); fixed-replica inputs for disabled scalers;
  exact-semantic-version validation on `n8n_chart_version` and
  `keda_chart_version`; opposite-path ignored-input `check` diagnostics
  (`checks.tf`); and ownership-neutral effective locals/outputs for network,
  cluster, namespace, Redis, GCS, and Workload Identity coordinates, plus new
  stable service/route outputs (`n8n_main_service_name`,
  `n8n_webhook_service_name`, `n8n_service_port`, `n8n_main_route_prefixes`,
  `n8n_webhook_route_prefixes`). Resource-level `count` gating for each layer
  lands in later `add-full-stack-modularity` sections; this section only adds
  the variable/locals/outputs contract and does not yet change what the
  module creates by default.
- Gated the network and Private Service Access ownership contract
  (`add-full-stack-modularity`, section 2): the VPC, subnetwork, secondary
  ranges, Cloud Router, and Cloud NAT now use `count = var.create_network ? 1
  : 0`, and the Private Service Access range/connection/cleanup delay now use
  `count = var.create_psa ? 1 : 0` independently of network ownership.
  Managed GKE, Cloud SQL, and Memorystore now attach to
  `local.effective_network_id`/`local.effective_network_self_link` and the
  effective secondary range names instead of the module-managed network
  resource directly, so they wire correctly onto an existing network,
  including a Shared VPC host project via `existing_network_project_id`. Added
  the `psa_tuning_ignored_when_existing` and
  `network_references_ignored_when_managed` opposite-path `check`
  diagnostics.
- Gated GKE ownership (`add-full-stack-modularity`, section 3): the GKE
  cluster, node pool, node service account, and node IAM bindings now use
  `count = var.create_gke ? 1 : 0`. With `create_gke = false`, a new
  `data.google_container_cluster.existing` lookup reads the named regional
  cluster (`existing_gke_cluster_name`) and its lifecycle postconditions
  enforce the observable prerequisites Terraform can check: VPC-native
  (alias IP) networking, Workload Identity enabled, and a same-project
  Workload Identity pool unless `existing_gke_workload_identity_pool` attests
  to an intentional cross-project binding. The module still trusts
  `existing_gke_prerequisites_attestation` for properties it cannot safely
  audit (permissions, reachability, capacity, native controllers). The
  effective cluster name/endpoint/CA/Workload-Identity-pool locals and the
  `gke_cluster_endpoint`/`gke_cluster_ca_certificate` outputs now resolve to
  the existing cluster's real values instead of `null`.
- Added the public `modules/controllers` submodule
  (`add-full-stack-modularity`, section 4), extracting the KEDA Helm release
  and the optional pd-balanced `StorageClass` behind a typed, validated
  contract (`install_keda`, `keda_namespace`, `keda_chart_repository`,
  `keda_chart_version`, `keda_helm_timeout`,
  `create_pd_balanced_storage_class`, `pd_balanced_storage_class_name`,
  `common_labels`) and `keda_installed`/`keda_namespace`/`keda_release_name`/
  `keda_chart_version`/`pd_balanced_storage_class_name` outputs. The root
  module invokes it by default (`controllers.tf`) and adds
  `install_keda` (replacing the previous unconditional KEDA install),
  `existing_keda_prerequisites_attestation` (required when `install_keda =
  false` and `n8n_worker_keda_enabled = true`), `keda_chart_repository`, and
  `create_pd_balanced_storage_class` root inputs; `keda_chart_version`
  is now passed through to the submodule. Root and n8n-release ordering
  (`google_container_node_pool.n8n` before the submodule, the submodule
  before `helm_release.n8n`) is unchanged. Added a direct-use example
  (`modules/controllers/examples/direct-use`) demonstrating the dependency a
  caller must add when composing this submodule with a separately managed
  n8n deployment instead of the root module.
- Gated PostgreSQL ownership and added Cloud SQL restore/encryption controls
  (`add-full-stack-modularity`, section 5): the Cloud SQL instance, generated
  password, database, user, and Cloud-SQL-only IAM binding
  (`google_project_iam_member.n8n_cloudsql_client`) now use `count =
  var.create_postgres_instance ? 1 : 0`. External PostgreSQL now accepts
  exactly one password source: the existing `n8n_database_password` (direct
  value) or the new `n8n_database_password_secret_ref` (a
  `{ name, key = optional(string, "password") }` reference to an existing
  Kubernetes Secret the module never reads); the module's own
  `kubernetes_secret.n8n_db` is skipped entirely on the Secret-reference path.
  Added provider-supported restore/clone inputs for a newly created
  module-managed instance (`postgres_clone_source_instance_name`,
  `postgres_clone_point_in_time`, `postgres_restore_backup_run_id`,
  `postgres_restore_source_instance_name`), a `data.google_sql_database_instance.restore_source`
  lookup that fails the plan on an observable `postgres_version` mismatch, and
  a `postgres_restore_without_encryption_key_continuity` `check` warning (the
  module always generates a new n8n encryption key, so restored/cloned n8n
  credentials will not be decryptable without an out-of-band fix-up). Added an
  explicit Cloud KMS create-or-reference contract: a shared key ring
  (`create_kms_key_ring`/`existing_kms_key_ring_id`/`kms_key_ring_location`,
  `kms.tf`) and a Cloud-SQL-specific key
  (`create_postgres_kms_key`/`existing_postgres_kms_key_id`), with
  `roles/cloudkms.cryptoKeyEncrypterDecrypter` granted to the Cloud SQL
  service agent only for a module-created key. Added the `postgres_host` and
  `postgres_kms_key_id` outputs and the `postgres_tuning_ignored_when_external`,
  `postgres_host_and_password_ignored_when_managed`, and
  `postgres_kms_ignored_when_external` opposite-path `check` diagnostics.
- Added `.github/CODEOWNERS` with a `*` rule owned by `@jrx` and
  `@buddy-n8n`.
- Added `SUPPORT.md` pointing to GitHub issues and the n8n community forum.
- Added `common_labels` (`map(string)`, default `{}`), merged into every
  taggable resource's label set alongside the module's built-in labels.
- Gated Redis ownership and completed the connection contract
  (`add-full-stack-modularity`, section 6): Memorystore now uses `count =
  var.create_redis_instance ? 1 : 0`. Added the full external Redis contract:
  `redis_host` (required when `create_redis_instance = false`), `redis_port`,
  `redis_tls_enabled`, `redis_username`, and exactly one of `redis_password`
  (direct) or `redis_password_secret_ref` (an existing Kubernetes Secret
  reference the module never reads). Added managed-Redis controls:
  `redis_tier` (`BASIC`/`STANDARD_HA`), `redis_auth_enabled`,
  `redis_transit_encryption_enabled`, and an explicit Cloud KMS
  create-or-reference pair (`create_redis_kms_key`/`existing_redis_kms_key_id`)
  mirroring the Cloud SQL pattern, with `roles/cloudkms.cryptoKeyEncrypterDecrypter`
  granted to the Memorystore service agent (`cloud-redis.iam.gserviceaccount.com`)
  only for a module-created key. Normalized the effective Redis
  host/port/TLS/username/password-secret coordinates (`locals.tf`) so n8n and
  KEDA always consume the same contract regardless of ownership; KEDA's
  `TriggerAuthentication` is now created whenever any password source is
  present, not only for managed AUTH, and an external ACL username is wrapped
  in a small module-managed Secret purely so KEDA's `authenticationRef` can
  reference it too. Added `redis_key_prefix` (the chart's `redis.prefix`),
  synchronized into KEDA's worker trigger list names, and
  `n8n_redis_timeout_threshold_ms` (the chart's `redis.timeout`), validated to
  be at least 30 seconds when `redis_tier = STANDARD_HA`, covering
  Memorystore's documented average failover unavailability window. Added the
  `redis_host`/`redis_port`/`redis_tls_enabled`/`redis_username`/
  `redis_kms_key_id` effective outputs and the `redis_tuning_ignored_when_existing`,
  `redis_external_settings_ignored_when_managed`, and
  `redis_kms_ignored_when_external` opposite-path `check` diagnostics. Wired
  `n8n_redis_timeout_threshold_ms` through the medium/large examples (both
  default `redis_tier` to `STANDARD_HA`).
- Gated GCS bucket ownership and added bucket-scoped Cloud KMS
  (`add-full-stack-modularity`, section 7): the GCS bucket now uses `count =
  var.create_gcs_bucket ? 1 : 0`, independent of HMAC identity ownership
  (`gcs_hmac_service_account_email`) and bucket IAM. With `create_gcs_bucket =
  false`, `existing_gcs_bucket_name` is required, and the module still grants
  least-privilege, bucket-scoped IAM to whichever HMAC identity is effective
  (module-managed or BYO). Added an explicit Cloud KMS create-or-reference
  pair (`create_gcs_kms_key`/`existing_gcs_kms_key_id`) mirroring the Cloud
  SQL/Memorystore pattern, with `roles/cloudkms.cryptoKeyEncrypterDecrypter`
  granted to the Cloud Storage service agent only for a module-created key;
  an existing bucket's encryption is never mutated. Added the
  `gcs_bucket_name` and `gcs_kms_key_id` effective outputs and the
  `gcs_tuning_ignored_when_existing` and `gcs_kms_ignored_when_existing`
  opposite-path `check` diagnostics.
- Gated namespace, Secret, and Workload Identity ownership
  (`add-full-stack-modularity`, section 8): the Kubernetes namespace now uses
  `count = var.create_namespace ? 1 : 0`, and every namespaced resource
  (Secrets, ServiceAccount, Helm release) routes through the ordering-safe
  `local.effective_namespace` contract instead of a resource-derived
  reference. Added `existing_n8n_core_secret_name`, a reference to an existing
  Kubernetes Secret holding the chart's core-Secret contract
  (`N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL`); when set,
  the module creates no core Secret and generates no encryption key, and
  `n8n_license_key_secret_ref` becomes required (the chart's core-Secret
  contract requires the license from a separate Secret, not
  `n8n_license_key`). Added `n8n_license_key_secret_ref`, completing the
  credential-Secret contract alongside the existing PostgreSQL, Redis, and
  GCS references. Normalized the n8n Workload Identity binding to the
  effective (managed or existing-cluster) Workload Identity pool and
  namespace, fixing the binding for cross-project existing GKE clusters and
  existing namespaces.
- Added Google Secret Manager access and n8n External Secrets controls
  (`add-full-stack-modularity`, section 9): `n8n_external_secrets_enabled`
  (master switch, default `true`, matching n8n's own default) and
  `n8n_external_secrets_update_interval`, wired to `N8N_DISABLED_MODULES` and
  `N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL` on every n8n pod. Added
  `n8n_secret_manager_enabled` plus a required, non-empty, wildcard-free
  `n8n_secret_manager_secret_ids` allow-list
  (`google_secret_manager_secret_iam_member.n8n`, `secret_manager.tf`),
  granting `roles/secretmanager.secretAccessor` to the n8n Workload Identity
  service account scoped to each listed secret only, never project-wide.
  Configuring n8n's Google Secret Manager vault-provider connection itself
  (Settings > External Secrets in the n8n UI) remains an in-product operator
  action this module does not automate.
- Added application artifact and runtime portability controls
  (`add-full-stack-modularity`, section 10): custom n8n image repository/tag
  (`n8n_image_repository`/`n8n_image_tag`), pull policy
  (`n8n_image_pull_policy`), image pull Secrets (`n8n_image_pull_secrets`,
  which moves ownership of the n8n Kubernetes ServiceAccount from the Helm
  chart to the module under a different name, carrying over the Workload
  Identity annotation), and a custom extensions path
  (`n8n_custom_extensions_path`) for baking community nodes into a custom
  image. Added independent task-runner image controls
  (`n8n_task_runner_image_repository`/`n8n_task_runner_image_tag`) applied to
  every applicable pod. Added `n8n_chart_repository`, a private n8n Helm
  chart repository input (HTTPS or `oci://`) mirroring the controller
  submodule's `keda_chart_repository` contract. Added
  `n8n_execution_data_storage_mode` (`database`, n8n's own default, or `s3`,
  reusing the effective GCS bucket/HMAC/Secret contract already configured
  for binary data); `filesystem` is rejected because pod filesystems are
  ephemeral and unshared in this module's queue-mode topology. Changed the
  default of `n8n_license_detach_floating_on_shutdown` to `false` (n8n's own
  upstream default is `true`, which is unsafe for this module's default
  multi-main topology). Extended `n8n_extra_env` reserved-name checks to
  cover every new managed setting without regressing OpenTelemetry, log
  streaming, metrics, package, template, or personalization controls.
- Gated ingress ownership and completed the application-scaler contract
  (`add-full-stack-modularity`, section 11): the global static IP, Cloud DNS
  A-record, GKE `Ingress`, `BackendConfig`, `FrontendConfig`, `Managed
  Certificate`, pre-shared/self-signed TLS certificate material, and
  load-balancer teardown delay now use `count = var.create_ingress ? 1 : 0`.
  Corrected the managed `Ingress` route contract to route `/webhook`,
  `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp` to the webhook
  service (previously only `/webhook` routed correctly) from the same
  `local.effective_webhook_route_prefixes` list the `n8n_webhook_route_
  prefixes` output already exposed. Added managed-ingress security controls:
  `ingress_ssl_policy_name` (attached via the `FrontendConfig`'s `sslPolicy`
  field) and a mutually exclusive `ingress_source_cidrs` (module-created
  Cloud Armor policy, `google_compute_security_policy.n8n`) or
  `existing_cloud_armor_policy_name` (attached via `BackendConfig.spec.
  securityPolicy`). Wired the existing `n8n_main_hpa_enabled`,
  `n8n_webhook_hpa_enabled`, and `n8n_worker_keda_enabled` switches (and their
  `*_fixed_replicas` fallbacks) into the n8n Helm release's `hpa`/`keda`/
  `multiMain`/`queueMode`/`webhookProcessor` values and gated the standalone
  webhook `HorizontalPodAutoscaler` (`scaling.tf`) and the KEDA
  `TriggerAuthentication` (`keda.tf`) on the same switches; these switches
  previously validated but had no effect. `static_ip` and `lb_ingress_ip` are
  now `null` when `create_ingress = false`. Added the
  `ingress_tuning_ignored_when_existing` opposite-path `check` diagnostic.
- Added a non-blocking managed-GKE capacity guardrail
  (`add-full-stack-modularity`, section 12, `capacity.tf`):
  `data.google_compute_zones.gke` and `data.google_compute_machine_types.gke`
  (module-managed GKE only, `count = var.create_gke ? 1 : 0`) estimate
  regional node-pool allocatable CPU/memory using GKE's documented per-node
  system-reserve formula, and the `gke_capacity_cpu_fits_requested_replicas`/
  `gke_capacity_memory_fits_requested_replicas` `check` blocks compare that
  estimate against the maximum CPU/memory the configured
  `n8n_main_hpa_max_replicas`/`n8n_main_fixed_replicas`,
  `n8n_worker_keda_max_replicas`/`n8n_worker_fixed_replicas`,
  `n8n_webhook_hpa_max_replicas`/`n8n_webhook_fixed_replicas`, and (when
  `n8n_task_runners_enabled`) the task-runner sidecar's requests on every
  main and worker pod could ever request. Both checks emit a warning, never a
  plan failure, and are skipped entirely (no computed verdict) for
  customer-managed GKE (`create_gke = false`) or when the machine-type
  lookup is unresolvable.
- Added four runnable, mock-tested customer-managed examples
  (`add-full-stack-modularity`, section 13): `examples/customer-managed-cluster`
  (existing GKE cluster only), `examples/customer-managed-redis` (external
  Redis-compatible service only), `examples/customer-managed-gcs` (existing
  bucket + BYO HMAC identity only), and `examples/customer-managed-everything`
  (every ownership switch flipped: network, GKE, Cloud SQL, Redis, GCS bucket,
  namespace, ingress, HPAs, worker KEDA, and the controller submodule's KEDA
  install), each with its own `terraform.tfvars.example`, README prerequisites,
  and `tests/defaults.tftest.hcl`. Extended the CI `docs`/`validate`/`test`/
  `tflint` matrices to cover all four new examples plus `modules/controllers`
  and `modules/controllers/examples/direct-use`, which were runnable and
  mock-tested (section 4) but not yet wired into CI.

- Curated the Google-specific Checkov security baseline
  (`add-google-parity-through-aws-0-4-0`, section 23): rotated every
  module-created CMEK key every 90 days (`kms.tf`); added always-on, PII-free
  Cloud SQL audit flags (`log_connections`, `log_disconnections`,
  `log_checkpoints`, `log_lock_waits`, `log_duration`, `log_hostname`,
  `log_min_error_statement`); added VPC Flow Logs on the module-managed
  subnet and an explicit low-priority deny-all-ingress firewall rule on the
  module-managed network (neither changes any actual allowed traffic);
  disabled GKE client-certificate authentication and enabled intranode
  visibility, Dataplane V2 network policy enforcement, and Shielded-node
  Secure Boot/Integrity Monitoring; and added a dedicated access-log bucket
  (`google_storage_bucket.n8n_access_logs`) for the module-managed GCS
  binary-data bucket. These are infrastructure behavior changes, not just
  explicit API defaults. In particular, Dataplane V2 replaces existing
  legacy-datapath clusters; see the breaking upgrade note below.
  Pinned Checkov to `3.3.17` for local use (`uv tool install checkov==3.3.17`
  or equivalent) and CI (`bridgecrewio/checkov-action@v12.3123.0`, the release
  tag whose bundled image is `ghcr.io/bridgecrewio/checkov:3.3.17`). Narrowly
  scoped, resource-level `checkov:skip` comments (which must sit inside the
  resource body to take effect, not above it) document the remaining findings
  Checkov cannot avoid: Cloud SQL SSL/pgAudit/full-statement-logging/major-version
  and Memorystore AUTH/in-transit-encryption stay off by default to match n8n's
  own default unencrypted client contract and remain caller-configurable
  opt-ins; GKE Binary Authorization and Google-Groups RBAC need a
  caller-owned policy/directory group this module cannot assume; the
  module-managed network's own firewall and every Cloud SQL dynamic
  `database_flags` value are real and verified by `terraform test`, but not
  visible to Checkov's static analysis once the resource is `count`-indexed
  or the flags come from a `dynamic` block (reproduced against minimal
  fixtures during this review); and the dedicated access-log bucket does not
  log access to itself. A full per-finding classification (fixed, scanner
  limitation, or intentional exception) is on record in this change's PR
  description and `openspec/changes/add-google-parity-through-aws-0-4-0/`
  history.

- Wired the credential-free chart-rendering regression check into CI and made
  the curated Checkov baseline a blocking gate
  (`add-google-parity-through-aws-0-4-0`, section 24): added a `chart-render`
  job to `.github/workflows/terraform-tests.yml` that installs a pinned Helm
  CLI (`v4.3.0`, via `azure/setup-helm@v5.0.1`) and runs
  `tests/scripts/check-n8n-chart.sh` with no credentials and no cluster; the
  script's own embedded self-check already proves a deliberately wrong
  expected value fails, and this job proves the same command fails CI, not
  just a local run. Flipped the `checkov` job's `soft_fail` from `true` to
  `false` now that section 23's curated baseline scans clean (110 passed, 0
  failed); a reintroduced finding (verified locally by temporarily reverting
  one of section 23's fixes) exits nonzero. Corrected `AGENTS.md`'s local
  verification loop: it now names the same twelve `validate`/`test`/`tflint`/
  `docs` targets CI covers (previously missing `examples/split-ingress`,
  the four `examples/customer-managed-*` examples, `modules/controllers`,
  and `modules/controllers/examples/direct-use`), runs each example/module
  target in its own subshell instead of a bare `cd examples/x && ...` chain
  (which left the shell inside the previous example directory and broke the
  next line's relative `cd`), and points the two controller
  `terraform-docs --output-check` invocations at the root `.terraform-docs.yml`
  via `--config` instead of the recursive-path default that silently prints
  CLI help. Also documents the local `check-n8n-chart.sh` and pinned `checkov`
  commands alongside the Terraform loop.

- Exposed the n8n main-pod HPA floor (or, in `examples/customer-managed-everything`,
  the fixed-replica floor) in every application example
  (`add-google-parity-through-aws-0-4-0`, section 25.1): `examples/small`,
  `examples/cloudflare`, `examples/godaddy`, `examples/split-ingress`,
  `examples/customer-managed-cluster`, `examples/customer-managed-gcs`, and
  `examples/customer-managed-redis` each add a `n8n_main_hpa_min_replicas`
  passthrough defaulting to `null` (the module's own default of 2, multi-main,
  is unchanged); `examples/medium` adds the same passthrough with an explicit
  default of `2`, its prior effective value; `examples/customer-managed-everything`
  adds a `n8n_main_fixed_replicas` passthrough (that example already sets
  `n8n_main_hpa_enabled = false`) defaulting to `2`, also its prior effective
  value. `examples/large`, which already exposed `n8n_main_hpa_min_replicas`
  with its own default of 3, is unchanged. Every example's default renders the
  same topology as before this change; setting the new input to 1 selects
  single-main queue mode. The controller submodule and its `direct-use`
  example are untouched. Added a `single_main_floor_produces_valid_plan` (or
  equivalent) plan-time test to every touched example.
- Exposed GKE boot-disk sizing and the database connection-pool ceiling as
  passthrough inputs in the two sizing examples
  (`add-google-parity-through-aws-0-4-0`, section 25.2): `examples/medium` and
  `examples/large` each add `gke_node_disk_size_gb` (default `100`),
  `gke_node_disk_type` (default `"pd-balanced"`), and
  `db_postgresdb_pool_size` (default `10`) passthroughs, matching the module's
  own defaults, so a load-tested deployment can tune boot-disk size/type and
  the per-pod TypeORM pool ceiling without editing the example itself. No
  Google resource sizing default changes; added plan-time tests confirming the
  default and an overridden value both produce a valid plan.
- Corrected `examples/large/README.md`'s stale worker-ceiling prose and added
  operator guidance (`add-google-parity-through-aws-0-4-0`, section 25.3): the
  sentence claiming a "worker max to 160" now reads 80, matching the
  `n8n_worker_keda_max_replicas` default already shown in the sizing table.
  Added a "Things to watch before you raise these ceilings further" section
  explaining that `db_postgresdb_pool_size` is a lazy per-pod ceiling whose
  aggregate demand (pool size times running pod count) can exceed Cloud SQL's
  `max_connections` before any autoscaler bound is reached; that cluster DNS
  query volume grows with pod count and `n8n_dns_config` is available if it
  becomes a bottleneck; that `n8n_node_max_old_space_size_mb` applies to every
  n8n container and must leave headroom under the smallest role's memory
  limit; that `gke_node_disk_size_gb` affects image/ephemeral-storage disk
  pressure under higher pod density, not only cost; that `n8n_pruning_max_age`/
  `n8n_pruning_max_count` bound Cloud SQL execution-table growth at this
  tier's higher execution-concurrency ceiling; and that opt-in Memorystore RDB
  persistence (`redis_persistence_enabled`) trades memory/latency overhead for
  last-snapshot (not point-in-time) recovery. No numeric table or default
  changed; the not-scale-validated warning is retained.
- Added `docs/upgrading-n8n.md` (`add-google-parity-through-aws-0-4-0`,
  section 26.1) covering every behavior change in this release: the
  `google_dns_record_set.n8n` resource-address change needing a manual
  `terraform state mv`, single-main/multi-main topology transitions, the
  chart's pre-existing replica-floor reset on every Helm upgrade, license
  Secret delivery, `n8n_encryption_key` restore/clone continuity, the full
  `n8n_extra_env`-to-dedicated-input reservation table, reference-only
  Secret/ConfigMap restart requirements, corrected canonical URLs (including
  the OAuth callback host for split-host deployments), Redis command/Bull
  prefix isolation, opt-in Memorystore RDB persistence, the Redis exporter
  and Cloud SQL backup/log additions, and caller-owned ingress continuity.
  Cross-linked from `README.md`'s day-2 operations section and referenced by
  `docs/customer-managed-infrastructure.md`, `docs/troubleshooting.md`, and
  `docs/destroy-cleanup.md` where each topic already lived.
- Extended `tests/scripts/README.md` and the read-only inspection portion of
  `tests/scripts/smoke-test.sh` for this release's new runtime contracts
  (`add-google-parity-through-aws-0-4-0`, section 26.2): main-topology
  classification (single-main `Recreate`/`minAvailable=0` vs multi-main),
  Redis command-channel/Bull prefix isolation (`QUEUE_BULL_PREFIX` vs
  `N8N_REDIS_KEY_PREFIX`), the opt-in Redis exporter's Deployment/Service
  health, the credentials-overwrite and task-runner custom-config
  reference-only mounts (existence/readability only, contents never read),
  the `NODE_OPTIONS` heap ceiling and pod `dnsConfig`, the managed license
  Secret's existence, and every `n8n_ingress_hosts` alias's `/healthz`
  reachability. Every added check is read-only: none of them drain a queue,
  restart a Deployment, rotate or read a Secret's contents, or apply
  infrastructure, and the script documents that boundary explicitly. The
  opt-in `LOAD_TEST=true` load-generation path is unchanged and still never
  runs automatically.
- Delivered `docs/manual-verification-checklist.md`
  (`add-google-parity-through-aws-0-4-0`, section 26.3): a 12-item checklist
  for every runtime-only scenario this release cannot prove without a live
  Google Cloud apply, single-main rollout/drain and return to multi-main,
  credentials-overwrite and task-runner ConfigMap rotation restarts, restored/
  cloned-database encryption-key continuity, separate-host OAuth callback
  registration, alias hostname TLS coverage across every `tls_mode`,
  split-ingress public/private route isolation, the Redis command/Bull prefix
  transition, the Redis exporter's TLS trust and metrics, Memorystore RDB
  persistence recovery, and n8n Enterprise license activation/entitlement
  boundaries. Every item states its safety prerequisites (disposable
  environment, drain-before-transition, destructive-item warnings) and its
  expected result, and every item is recorded as "Not run" by default;
  delivering the checklist, not running it, is what this section requires.
  Linked from `README.md`'s day-2 operations section and from
  `tests/scripts/README.md`.
- Linked `openspec/changes/add-google-parity-through-aws-0-4-0/parity-matrix.md`
  (`add-google-parity-through-aws-0-4-0`, section 26.4) from `README.md`'s
  day-2 operations section as the durable record of every AWS `0.4.0`
  feature group's disposition (ported, Google-adapted, already covered, or
  excluded with a stated reason); every port/adaptation entry in that matrix
  maps to an input, fix, or test landed in one of this change's numbered
  sections, and every exclusion remains explicit rather than silently
  dropped.
- **`n8n_graceful_shutdown_timeout`** (chart `redis.worker.timeout`, renders
  `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`). Seconds n8n waits for in-flight
  executions to finish on SIGTERM before exiting on its own. Must go through
  this input rather than any `extra_env` input: chart `1.13.0` renders this
  ConfigMap key unconditionally on every n8n container, unlike the three
  `n8n_queue_worker_*` settings above, and `extraEnv` is appended after it,
  so a caller duplicate would not fail, Kubernetes silently keeps the
  `extraEnv` copy instead of the chart's real value, with no warning (see
  **Fixed** below). An explicit value plus `n8n_prestop_sleep` must stay
  strictly below `n8n_termination_grace_period`, or validation fails,
  because Kubernetes would SIGKILL the pod before n8n finishes shutting
  down. Left `null`, the module sends no override, the chart keeps its own
  30s default, and existing releases see no Helm values change. In that case
  the same rule applied to the 30s default is only a warning, the new
  `graceful_shutdown_fits_grace_period` check, so configurations that
  planned before still plan. The warning is skipped for a custom
  `n8n_chart_repository`, whose default the module cannot verify.
  `tests/scripts/check-n8n-chart.sh` fails if the pinned chart's rendered
  default drifts from `local.n8n_chart_default_graceful_shutdown_timeout`.
  Ported from terraform-aws-n8n#148 (fixes terraform-aws-n8n#147).
- `tests/scripts/smoke-test.sh` detects the single-main topology
  (`local.n8n_single_main`, one selected main replica) from the main
  Deployment spec and asserts its safeguards: a module-owned main HPA
  pinned to 1/1 (or one replica when `n8n_main_hpa_enabled = false`), the
  `Recreate` strategy, and PDB `minAvailable = 0`. It no longer reports a
  single-main install as a degraded multi-main one. The chart-rendered
  `N8N_MULTI_MAIN_SETUP_ENABLED` entry (a `configMapKeyRef`) is the signal
  for multi-main; a literal value for that name is the module's own
  election staging at one replica (`n8n_main_leader_election_enabled =
  true`) and is accepted as single-main. A fixed-size HPA (min equals max)
  no longer warns that it is at max replicas. This replaces the later
  result-based "Main Topology" check, which classified the topology from
  the replica count and strategy it was meant to verify, and only warned on
  a wrong PDB. Adapted from the terraform-aws-n8n smoke test.

### Fixed
- `tests/scripts/check-checkov.sh`'s opt-in checkov pass now proves it
  evaluated the root module's opt-in resources, not an example's copy of
  them. Every `examples/*` directory calls `module "n8n" { source =
  "../.." }` with its own tfvars (which do not set the opt-in switches this
  pass exists to flip on). Left in scope, checkov can attribute
  `observability.tf`'s opt-in `redis_exporter` Deployment/Service to one
  of those module calls (reported as `module.n8n.<address>`) instead of
  to the root module under this pass's `--var-file`. This was not stable
  across environments: CI on `main` reached both resources, while one
  local run dropped the Service. The reachability check's substring match
  also accepted a `module.n8n.`-qualified address as proof. The opt-in
  pass now runs with `--skip-path examples`, and the reachability check
  accepts only exact root-module addresses (with an optional count
  index). The opt-in pass reaches both resources with 0 failed checks;
  the default pass (unaffected, still scans every `examples/*`) is
  unchanged at 111 passed, 0 failed, 189 skipped.

- `n8n_extra_env`, `n8n_worker_extra_env`, and `n8n_worker_pools[*].extra_env`
  now reject `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` at plan time. Chart `1.13.0`
  renders that ConfigMap key unconditionally on every n8n container from
  `redis.worker.timeout`, and `extraEnv` is appended after it in every
  deployment template, so a caller-supplied duplicate previously passed
  `terraform plan` with no error at all: Kubernetes does not reject
  duplicate env names, it silently keeps the last entry in the list, so the
  caller's raw value would replace the chart's real one with no plan- or
  apply-time warning. The same guard already existed for
  `n8n_queue_worker_lock_duration` and its siblings; this closes the gap for
  the graceful shutdown timeout. **Breaking for callers who set this name
  through any of these inputs:** their `terraform plan` now fails. Remove the
  `extra_env` entry and set `n8n_graceful_shutdown_timeout` (a number of
  seconds) instead. Two differences to check first: the input applies to
  every n8n container, so a value that was set only on workers
  (`n8n_worker_extra_env`) or only on one pool now also reaches mains and
  webhook processors, and different values per pool can no longer be kept;
  and the value plus `n8n_prestop_sleep` must stay below
  `n8n_termination_grace_period`, which the old `extra_env` route never
  checked. Ported from terraform-aws-n8n#148 (fixes terraform-aws-n8n#147).
- `n8n_fqdn`, `n8n_additional_domains`, and `n8n_image_pull_secrets` now
  bound each dot-separated label to the actual DNS-1123 label rule (1 to 63
  characters, alphanumeric start and end), not just a total-length check.
  `n8n_fqdn`/`n8n_additional_domains` previously accepted an empty label
  (`n8n..example.com`) or a label starting/ending with a hyphen anywhere
  but the very first character of the whole string; `n8n_image_pull_secrets`
  bounded only the 253-character total length. Every such value was always
  going to be rejected downstream (GKE Ingress/`ManagedCertificate`, or the
  Kubernetes Secret name rule); it now fails at `terraform plan` instead.
- `tls_mode = "self_signed"` now rejects an `n8n_fqdn` over 64 characters at
  plan, via a `precondition` on `tls_self_signed_cert.self_signed`. RFC 5280
  caps a certificate's Common Name at 64 octets, tighter than the
  253-character whole-hostname limit; previously an over-length hostname
  failed deep inside the `tls` provider mid-apply. `google_managed`,
  `custom`, and `secret` TLS keep only the existing 253-character rule,
  since they carry the hostname as a Subject Alternative Name, not a
  Common Name.
- `tests/scripts/smoke-test.sh` now fails loudly when the kubectl context
  switch (`gcloud container clusters get-credentials ...`) fails, and refuses
  to continue unless `kubectl config current-context` matches the GKE context
  for the deployment's cluster. Previously, under `set -e`, a failed switch
  aborted the script with no message; without it, checks would have run
  against whatever context happened to be current.
- Documented that `n8n_worker_concurrency` is not the effective worker
  concurrency with the defaults. Live testing on n8n 2.38.7 showed the worker
  logs `Concurrency: 100`: n8n replaces the `--concurrency` flag with
  `N8N_CONCURRENCY_PRODUCTION_LIMIT` whenever that variable is not -1, and the
  module emits it from `n8n_execution_concurrency_limit` (default 100) on every
  role. KEDA still scales workers on queue depth, but additional workers only
  receive jobs once the first holds 100. Both variable descriptions now state
  this; behaviour is unchanged pending a decision on per-role emission.
- Explicitly set Memorystore persistence to `DISABLED` when
  `redis_persistence_enabled = false`. Previously, omitting the
  optional/computed block retained RDB persistence on an existing instance.
  Snapshot schedule inputs are omitted while disabled. An existing instance
  still using RDB with this input set to false now plans a disabling update;
  review the loss of snapshot recovery before applying.
- Made the split-ingress example's private Ingress HTTPS-only. Disabling
  HTTP avoids requiring a `SHARED_LOADBALANCER_VIP` address for simultaneous
  HTTP and HTTPS forwarding rules. The public Ingress is unchanged.
- Granted `group:cloud-storage-analytics@google.com` the bucket-scoped
  `roles/storage.objectCreator` role on the managed access-log bucket so
  Cloud Storage can deliver logs. No logging IAM is created for
  customer-managed buckets.

- Pinned the managed-GKE Workload Identity binding to the project's own pool:
  `existing_gke_workload_identity_pool` is now genuinely ignored when
  `create_gke = true` (it previously rewrote the binding member silently,
  contradicting its own description), and a new
  `gke_references_ignored_when_managed` opposite-path `check` diagnostic warns
  when any existing-cluster reference (`existing_gke_cluster_name`,
  `existing_gke_workload_identity_pool`,
  `existing_gke_prerequisites_attestation`) is set on the managed path.
- Made the `n8n_image_pull_policy` validation compatible with Terraform 1.9
  (the CI-pinned version), which does not short-circuit `||` and rejects
  `contains()` with a null needle, failing `terraform validate` in every
  example.
- Mocked the new `google-beta` provider in every root and example test suite
  and configured it (mirroring the `google` provider) in every example's
  `providers.tf`/`versions.tf`, so `terraform test` runs credential-free in CI
  and a real apply from an example root has an explicit `google-beta`
  configuration for the CMEK service-agent resources.
- Rejected fractional values on `n8n_main_fixed_replicas`,
  `n8n_webhook_fixed_replicas`, and `n8n_worker_fixed_replicas`; a replica
  count must be a whole number.
- Documented the back-out procedure for module-created CMEK keys (protected by
  `prevent_destroy`) in `docs/destroy-cleanup.md` and on each
  `create_*_kms_key` description, and the verified pinned-chart handling of
  empty `redis.prefix`/`redis.username` values (Go-template truthiness falls
  back to n8n's own defaults, keeping KEDA's `bull`-prefixed trigger lists in
  sync).
- Trusted the Google-managed Memorystore service CA from every n8n workload
  and the KEDA Redis scaler when module-managed Redis transit encryption is
  enabled, instead of leaving both clients unable to verify the Redis server
  certificate at runtime.
- Materialized the Cloud SQL, Memorystore, and Cloud Storage Google-managed
  service agents before granting module-created CMEK key IAM, so a first apply
  in a clean project no longer fails because the service account does not yet
  exist.
- Prevented ignored CMEK switches from creating protected KMS keys, IAM
  bindings, or a key ring when the corresponding Cloud SQL, Redis, or GCS
  service is customer-managed. Service-agent IAM now always derives from
  `project_id`.
- Corrected namespace ordering so every module-managed Kubernetes Secret,
  ServiceAccount, Helm release, and KEDA `TriggerAuthentication` waits for a
  module-managed namespace before creation.
- Corrected module-managed Private Service Access allocation ownership for
  Shared VPC, placing the reserved range in `existing_network_project_id`.
- Made module-created GCS-only KMS rings follow the bucket's compatible
  location (`EU` maps to the KMS `europe` multi-region), and added plan-time
  rejection when a shared ring cannot satisfy all selected service locations.
- Enforced both halves of Cloud SQL restore and point-in-time clone input
  pairs, and suppressed the encryption-key continuity warning when an existing
  core Secret already preserves the original key.
- Added a combined root-module test proving the fully customer-managed
  composition omits every selected infrastructure, namespace, ingress,
  controller, and scaler resource.
- Added the missing `deny(403)` rule for the `cve-canary` preconfigured
  expression (log4j2 JNDI message-lookup pattern, CVE-2021-44228 aka
  log4jshell) to the module-managed Cloud Armor policy created when
  `ingress_source_cidrs` is non-empty (`add-full-stack-modularity`, section
  15 final verification; Checkov `CKV_GCP_73`).

### Changed
- CI checkov pin bumped to `bridgecrewio/checkov-action@v12.3126.0` (was
  `v12.3123.0`), which bundles Checkov `3.3.20` (was `3.3.17`); local
  installs should move to `checkov==3.3.20` to match. The range adds
  `CKV_AWS_394` (3.3.19, AWS-only, not applicable to this module) and a
  `terraform_plan` parser fix for `forget`-action resources (3.3.20).
  Re-verified against this module's curated baseline: the default pass is
  unchanged at 111 passed, 0 failed, 189 skipped, and the opt-in pass has
  0 failed checks. `TF_VERSION` is also behind upstream (see
  `docs/versioning.md`'s CI toolchain table) but is deliberately not
  bumped here: it needs a specific reason per its own tier note, not a
  routine bump.
- `TFLINT_VERSION` bumped to `v0.64.0` (was `v0.53.0`), an 11-minor jump. Re-ran
  `tflint --init` and `tflint --format compact` across the full target matrix
  (module root, every example, `modules/controllers`, and its own
  `examples/direct-use`): zero new findings from rules added since `v0.53.0`.

- **Breaking:** the `kubernetes` provider floor is bumped to `~> 3.0` (was
  `~> 2.0`), across the root module, `modules/controllers`, and every
  example. Provider 3.0 deprecates every unversioned Kubernetes resource
  type in favor of its `_v1` twin; this module still uses
  `kubernetes_namespace` and several `kubernetes_secret` resources
  unversioned, so they now plan with a cosmetic "Deprecated Resource"
  warning. Not renamed in this release: the provider has no `moved` support
  across that rename (`hashicorp/terraform-provider-kubernetes` issue
  #2812, still open), so renaming would force every existing deployment to
  destroy and recreate its namespace. If your root module declares its own
  `kubernetes` provider constraint at `~> 2.0`, widen it first, or
  `terraform init` cannot satisfy both.
- `time` provider bumped to `~> 0.14` (was `~> 0.12`): additive-only
  upstream, no plan diff.
- Default `n8n_chart_version` bumped to `1.11.0` (was `1.10.1`). Re-verified
  with `tests/scripts/check-n8n-chart.sh`: chart 1.11.0's two upstream
  behavior changes (the KEDA trigger `listName` default and a chart-managed
  `/mcp/` webhook Ingress rule) are already inert here, since this module
  sets `listName` itself and manages its own Ingress `/mcp` route rather
  than the chart's.
- Default `n8n_chart_version` bumped to `1.13.0` (was `1.11.0`; n8n-hosting
  v1.13.0, 2026-09-23, which bundles n8n `2.40.5` as its `appVersion`). Three
  chart-side behavior changes reach this module. The `values.yaml` diff
  (`tests/scripts/chart-values-diff.sh`) shows only the pause keys and the
  `image.tag` default; the other two live in `templates/`, so diff those too
  on a future bump (see `docs/versioning.md`).
  - **Default n8n version is now pinned, not floating.** The chart's
    `image.tag` default moved from the mutable `stable` tag to its own
    `appVersion`, so a deployment leaving `n8n_image_tag = null` now runs
    exactly n8n `2.40.5` and only moves when `n8n_chart_version` does,
    instead of picking up whatever `stable` resolved to on each pod
    (re)start. Reproducibility improvement; if you relied on the floating
    tag for hands-off n8n upgrades, pin `n8n_image_tag` yourself from now
    on. `n8n_image_tag`'s description and the `examples/*` passthroughs no
    longer describe `stable` as the default.
  - **Worker replicas are left to KEDA on every apply** (n8n-hosting#201).
    With `n8n_worker_keda_enabled = true` (the default) the chart no longer
    renders the worker Deployment's `replicas` field, so a `terraform apply`
    that upgrades the Helm release no longer resets KEDA-scaled workers back
    to `n8n_worker_keda_min_replicas`. One-time effect on the **first**
    apply on this chart for a stack already applied from an earlier commit:
    Helm removes the field it used to manage and the worker Deployment drops
    to 1 replica whatever the floor. The HPA that KEDA manages restores
    `n8n_worker_keda_min_replicas` (not the earlier live count), and a
    running execution can be interrupted once n8n's 30-second
    `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` passes; see
    [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md#replica-floor-reset-on-every-helm-upgrade).
    The webhook-processor Deployment is **not** affected: this module keeps
    the chart's own webhook HPA/KEDA switches off and scales it through
    `scaling.tf`'s external `HorizontalPodAutoscaler`, which the chart cannot
    see, so its `replicas` is still stamped on every apply as before.
    `tests/scripts/check-n8n-chart.sh` now renders a KEDA-on fixture and
    asserts both halves (worker `replicas` absent, webhook-processor
    `replicas` present) so a later chart bump cannot flip either silently.
  - **Main pods lose the task-runner sidecar** (n8n-hosting#179, shipped in
    chart 1.12.0, unchanged through 1.13.0). The chart now renders the
    sidecar, its env, and the launcher ConfigMap mount on main only in
    standalone mode (`n8n.mainTaskRunnersEnabled`); in queue mode, which
    this module always runs, n8n offloads manual executions to workers and
    starts no runner broker on main, so only worker pods carry the
    sidecar. Main pods roll once on the upgrade to drop the container.
    `n8n_task_runner_*` sizing, `n8n_task_runner_custom_config`, and
    `n8n_task_runner_timeout` now apply to workers only. `capacity.tf`'s
    node-capacity guardrail no longer adds the sidecar request to the main
    ceiling, but only for a pinned chart it can verify carries the fix
    (`local.n8n_chart_has_worker_only_runners`: the default's own OCI
    repository and a chart version of `1.12.0` or `1.13.0`); any other
    `n8n_chart_version` (a private mirror, an unnumbered preview build such
    as `examples/worker-pools`' `1.11.0-preview.workerpools.1`, which
    predates #179, or a future/older numbered release) keeps the
    conservative allowance, since the module cannot see what an arbitrary
    pin's templates actually render. Same shape and same local name as
    terraform-aws-n8n's/terraform-azurerm-n8n's own
    `n8n_chart_has_worker_only_runners`. `tests/scripts/check-n8n-chart.sh`
    asserts the sidecar renders on the worker Deployment and not on main
    or webhook-processor at the pinned default; `defaults.tftest.hcl` pins
    both the verified and unverified branches of the capacity formula;
    `tests/scripts/smoke-test.sh` looks for the sidecar on the worker pod.
    Same change as terraform-aws-n8n / terraform-azurerm-n8n.
  - The chart's new `keda.worker.pause`/`pausedReplicaCount` are exposed as
    `n8n_worker_keda_pause`/`n8n_worker_keda_paused_replica_count` (see
    **Added**). The `keda.webhookProcessor` equivalents are deliberately not
    exposed: no webhook `ScaledObject` exists here for the annotation to act
    on (external HPA, above).
  - Live-verified 2026-09-23 as an in-place upgrade of a scratch
    `examples/small` deployment (`n8n_worker_keda_min_replicas = 2` so the
    dip is observable; Cloudflare A-record, `tls_mode = google_managed`):
    baseline apply on `1.11.0` (46 added, pods on `n8n:stable`), then
    `terraform plan` on `1.13.0` was exactly `0 to add, 1 to change, 0 to
    destroy`, `helm_release.n8n` `version` only. During the 2m43s Helm
    upgrade a 1s watcher saw the worker Deployment's `spec.replicas` go
    `2 -> 1` at +8s, KEDA restore it to `2` at +23s (one 15s poll), and
    ready replicas return to 2 at +74s once the new image rolled; the
    main and webhook-processor Deployments stayed at 2 throughout. After
    the upgrade: release revision 2 `deployed`, chart `n8n-1.13.0`, app
    version `2.40.5`, all six pods `Running` on `n8n:2.40.5`, the rendered
    worker manifest carries no `replicas` field while the webhook-processor
    manifest still does, and the immediately following `terraform plan`
    reported "No changes."
- `gke_node_max_per_zone` now defaults to `4` (was `2`). With the previous
  default the module's own replica maxima (`n8n_main_hpa_max_replicas = 20`,
  `n8n_webhook_hpa_max_replicas = 50`, `n8n_worker_keda_max_replicas = 10`,
  plus task-runner sidecars) exceeded the estimated capacity of the 6-node
  pool, so a stock deployment (including `examples/small`) tripped both
  capacity `check` warnings on every plan and apply, as observed live on
  2026-09-18. 12 `e2-standard-4` nodes is the smallest ceiling whose
  estimate covers those maxima; it is an autoscaler ceiling only, so baseline
  cost is unchanged, but reaching it needs at least 48 vCPUs of regional
  quota. For an existing deployment this is an in-place `max_node_count`
  update on the node pool. The capacity estimate now also caps the zone
  count at 3, GKE's default node locations for a regional pool, instead of
  counting every zone in the region (a four-zone region such as
  `us-central1` was overstated by a third), and the warning text no longer
  suggests the cluster autoscaler can grow past `gke_node_max_per_zone`.

- **Breaking:** the Private Services Access connection
  (`google_service_networking_connection.psa`) is now abandoned on destroy
  (`deletion_policy = "ABANDON"`) instead of deleted, and the destroy-time
  pause that tried to make that delete succeed is removed:
  `time_sleep.wait_for_psa_cleanup` and the `psa_cleanup_destroy_duration`
  input are gone. GCP's `connections.delete` API rejects the call with
  `Producer services ... are still using this connection` for anywhere from
  minutes to days after Cloud SQL and Memorystore are actually deleted
  (terraform-provider-google#16275), with no signal for when the release
  completes, so no fixed pause could make it reliable; a live `examples/small`
  teardown on 2026-09-17 still stalled there after the 3-minute default.
  Abandoning does not remove the `servicenetworking-googleapis-com` peering
  itself. The Google provider and GCP VPC documentation both state that a
  remaining peering blocks network deletion; a live `examples/small` teardown
  and a throwaway-VPC check on the same day nevertheless observed the VPC
  delete succeed with only that peering left. Treat this as observed, not
  guaranteed: the compute-level `gcloud compute networks peerings delete`
  recovery stays documented in `README.md` and `docs/destroy-cleanup.md`. On
  `create_network = false` the peering remains on the caller's VPC while the
  module-owned PSA range is deleted; `docs/destroy-cleanup.md` covers removal
  and the re-deploy path. Cloud SQL and Memorystore now depend on the
  connection directly, so creation ordering is unchanged. A caller passing
  `psa_cleanup_destroy_duration` must drop it. An existing deployment sees
  `time_sleep.wait_for_psa_cleanup[0]` destroyed on its next apply; that
  destroy pauses once for the resource's recorded `destroy_duration` (3m by
  default) and touches nothing in GCP. Run `terraform apply` once on this
  version before `terraform destroy`: the provider reads `deletion_policy`
  from state, so a destroy without an intervening apply still uses the old
  API-delete behavior.

- **Breaking, minor release only:** managed GKE now uses Dataplane V2
  (`datapath_provider = "ADVANCED_DATAPATH"`). With Google provider 6.x,
  upgrading a `LEGACY_DATAPATH` cluster forces replacement and workload
  downtime. The default is retained intentionally; no managed-path legacy
  opt-out is provided. A state-address move cannot avoid replacement.
  Rehearse the migration and review deletion protection, caller-managed
  Kubernetes objects, and provider reconnection before applying. See
  [the GKE migration procedure](./docs/upgrading-n8n.md#gke-dataplane-v2-requires-cluster-replacement).
  Existing Dataplane V2 clusters and customer-managed clusters are unaffected
  by this datapath setting.

- **Breaking:** `cluster_name` is replaced by `friendly_name_prefix` as the
  naming driver for every Google Cloud resource the module creates. The
  naming scheme is `<friendly_name_prefix>-n8n<-suffix>` (e.g. the GKE
  cluster is `<friendly_name_prefix>-n8n`, Cloud SQL is
  `<friendly_name_prefix>-n8n-pg`). `friendly_name_prefix` is required, must
  not contain `n8n`, and is capped at 20 characters so derived
  service-account IDs stay within Google Cloud's 30-character `account_id`
  limit. The Workload Identity service account is
  `<friendly_name_prefix>-n8n-wi`.
- **Breaking:** output `cluster_name` is renamed to `gke_cluster_name`,
  `cluster_endpoint` to `gke_cluster_endpoint`, and `cluster_ca_certificate`
  to `gke_cluster_ca_certificate`.
- **Breaking:** database variables are renamed to HVD-style, service-oriented
  names: `create_database` to `create_postgres_instance`, `db_host` to
  `n8n_database_host`, `db_password` to `n8n_database_password`, `db_name` to
  `n8n_database_name`, `db_username` to `n8n_database_user`,
  `cloudsql_database_version` to `postgres_version`, `cloudsql_edition` to
  `postgres_edition`, `cloudsql_tier` to `postgres_machine_type`,
  `cloudsql_availability_type` to `postgres_availability_type`,
  `cloudsql_disk_size` to `postgres_disk_size`, and
  `cloudsql_deletion_protection` to `postgres_deletion_protection`. Semantics,
  types, and defaults are unchanged; only the names move.
- **Breaking:** outputs `cloudsql_private_ip` and `cloudsql_connection_name`
  are renamed to `postgres_private_ip` and `postgres_connection_name`; output
  `db_password` is renamed to `n8n_database_password`.
- **Breaking:** Redis and GKE variables are renamed to HVD-style,
  service-oriented names: `memorystore_tier` to `redis_tier`,
  `memorystore_memory_gb` to `redis_memory_size_gb`,
  `memorystore_redis_version` to `redis_version`,
  `memorystore_auth_enabled` to `redis_auth_enabled`, `node_machine_type` to
  `gke_node_type`, `node_min_per_zone` to `gke_node_min_per_zone`,
  `node_max_per_zone` to `gke_node_max_per_zone`, `node_disk_size_gb` to
  `gke_node_disk_size_gb`, `node_disk_type` to `gke_node_disk_type`,
  `cluster_deletion_protection` to `gke_deletion_protection`,
  `enable_private_nodes` to `gke_enable_private_nodes`, `master_ipv4_cidr` to
  `gke_control_plane_cidr`, and `master_authorized_networks` to
  `gke_control_plane_authorized_networks`. Semantics, types, and defaults are
  unchanged; only the names move.
- **Breaking:** output `memorystore_host` is renamed to `redis_host`.
- **Breaking:** application and DNS variables are renamed to HVD-style,
  service-oriented names: `n8n_domain` to `n8n_fqdn`, `namespace` to
  `n8n_kube_namespace`, `k8s_service_account_name` to
  `n8n_kube_svc_account`, and `dns_managed_zone` to `cloud_dns_zone_name`.
  Semantics, types, and defaults are unchanged; only the names move.
- **Breaking:** output `namespace` is renamed to `n8n_kube_namespace`.

### Removed

- The single-instance code path from `tests/scripts/smoke-test.sh` (the
  SQLite PVC check, task runner sidecar and Python runner checks on
  `n8n-main`, and the JS + Python execution workflow), the `DEPLOY_MODE`
  variable, and every mode branch. This module always deploys queue mode
  with dedicated worker pods, so the branch tested a topology the module
  never creates, and, worse, a broken deployment missing its `n8n-worker`
  Deployment was silently tested as that other topology instead of
  failing. The script now has one code path and fails when `n8n-worker` is
  absent. Only a `NotFound` error counts as absent: any other kubectl error
  (RBAC, API timeout, expired credentials) is reported as an unreadable
  Deployment instead. When it is absent, the worker-dependent checks (pod
  floor, worker task runner sidecar, worker autoscaler, Redis probe, queued
  workflow execution, load test) skip with a pointer to that failure, so
  one root cause is reported once instead of as a cascade. Ported from terraform-aws-n8n#152 at commit
  `a6672698bd448f1f58c1a6928162c0707a227255` (that PR was still open when
  ported).

### Security

- `redis_exporter_image`'s default is now pinned by digest as well as tag
  (`oliver006/redis_exporter:v1.90.0@sha256:a129504e65b87c54f79bc92f1afc403475e8ff646a3d7512de469904ceddf986`,
  the multi-arch index, verified against the live registry manifest). The
  tag alone was mutable, so the default `IfNotPresent` pull policy could
  keep running a superseded image once the tag moved; the digest makes the
  reference immutable. Deployments with `redis_exporter_enabled = true`
  roll the exporter pod once on the next apply; nothing changes for the
  default `false`. Fixes checkov `CKV_K8S_15` and `CKV_K8S_43` on merit,
  surfaced only once the new opt-in checkov pass (see **Added**) actually
  scans the resource. The one remaining finding, `CKV_K8S_11` (no CPU
  limit), is a deliberate trade annotated at the resource: a CFS-throttled
  exporter reports late during exactly the incident it exists for.

## [0.1.0] - 2026-07-21

Initial release.

### Added

- Production-grade n8n queue-mode deployment on Google Kubernetes Engine
  (GKE): multiple n8n main instances, dedicated worker pods, and webhook
  processors, fronted by a native GKE Ingress (Google Cloud L7 load
  balancer). Requires an n8n Enterprise license for multi-main.
- Regional, VPC-native GKE cluster with a managed node pool and native
  node-pool autoscaling, plus Workload Identity so pods authenticate to
  Google Cloud APIs without static keys.
- Cloud SQL for PostgreSQL over Private Service Access, with regional HA
  and configurable tier, disk, and version.
- Memorystore for Redis over Private Service Access, with optional AUTH.
- Google Cloud Storage bucket for n8n binary data, accessed through the
  S3-compatible endpoint via an HMAC key (with a bring-your-own-key mode
  for projects that cannot relax the service-account-key org policy).
- KEDA-based worker autoscaling driven by Redis queue depth, plus a CPU
  HPA for webhook processors.
- TLS options via `tls_mode`: `google_managed` (default, ManagedCertificate),
  `secret` (existing Kubernetes TLS secret, e.g. cert-manager), `custom`
  (bring-your-own PEM), and `self_signed`.
- Optional Cloud DNS A-record management, or bring your own DNS.
- Configurable Private Service Access teardown pause
  (`psa_cleanup_destroy_duration`) so `terraform destroy` clears the
  peering cleanly.
- Example roots: `small`, `medium`, `large`, `cloudflare` (cert-manager
  plus Cloudflare DNS-01), and `godaddy` (GoDaddy-managed DNS).
- Plan-time `terraform test` suites at the module root and in every
  example, using mocked providers so they run offline.
- Dedicated least-privilege service account for the GKE node pool
  (logging, monitoring, and Artifact Registry roles only), instead of the
  project's default Compute Engine service account.
- Pinned KEDA Helm chart version, configurable via `keda_chart_version`,
  so applies are reproducible instead of floating to the latest chart.
- GCS bucket hardening: public access prevention enforced and a lifecycle
  rule that deletes noncurrent object versions beyond the newest three.
- Fail-fast cross-variable validations for the BYO HMAC inputs
  (`gcs_hmac_*`) and an RFC1035 naming check on `cluster_name`, so
  misconfigurations stop the plan instead of surfacing mid-apply.

[0.1.0]: https://github.com/n8n-io/terraform-google-n8n/releases/tag/v0.1.0
