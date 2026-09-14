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
  module-managed network (neither changes any actual allowed traffic); made
  GKE client-certificate authentication, intranode visibility, Dataplane V2
  network policy enforcement, and Shielded-node Secure Boot/Integrity
  Monitoring explicit instead of relying on unstated API defaults; and added a
  dedicated, short-lived access-log bucket (`google_storage_bucket.n8n_access_logs`)
  for the module-managed GCS binary-data bucket. None of these change any
  existing default that other tests, examples, or the Helm release depend on.
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
  history. `soft_fail` on the CI `checkov` job stays `true` until a follow-up
  section wires the pinned scan into the same blocking gate as the other CI
  jobs; a scan of this baseline already returns zero failed checks.

### Fixed

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
