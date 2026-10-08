# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md, Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Added

- `docs/build-time-decisions.md`: lists inputs that are hard or impossible to
  change after the first apply (GKE region, private nodes and control-plane
  CIDR, Dataplane V2, subnet and secondary ranges, the Private Services
  Access range, Cloud SQL region and CMEK, Memorystore tier, region, transit
  encryption and CMEK, GCS location, and the n8n encryption key), checked
  against `hashicorp/google` `v6.50.0`. A second table lists inputs that
  update in place but can still disrupt workloads (GKE node machine type and
  disk, Redis AUTH, Cloud SQL edition and private network, GCS CMEK, and the
  FQDN). Linked from README.md's day-2 operations section.
- `docs/shared-responsibility.md`: a single table summarizing what the
  module does versus what the caller owns across cluster security add-ons,
  network egress and DNS, edge protection, TLS, secrets and Terraform state,
  backup/restore, observability, upgrades, license, and quotas, linked from
  the README's "Out of scope" section.
- `docs/ingress-options.md`: when to pick GKE Gateway API, an internal
  Application Load Balancer, Istio/Cloud Service Mesh, or a third-party
  controller instead of the module's default native GKE Ingress, with
  dated, cited Google Cloud documentation references. It also covers what
  switching an existing deployment to `create_ingress = false` destroys
  (static IP, DNS records, certificates, and the module-created Cloud Armor
  policy when `ingress_source_cidrs` is set), the
  `BackendConfig`/`FrontendConfig` settings to review on a replacement
  ingress, and the proxy-only subnet that the internal and regional
  Application Load Balancers discussed there need but the module's VPC does
  not create. Linked from
  README.md's Architecture section and cross-linked from
  `docs/istio-ingress.md`; does not duplicate the routing contract already
  documented in `docs/customer-managed-infrastructure.md` and
  `docs/istio-ingress.md`.
- `redis_maxmemory_policy`: sets Memorystore's `maxmemory-policy` on the
  module-managed instance (default `"noeviction"`). The LFU policies
  (`volatile-lfu`, `allkeys-lfu`) need Redis 4.0 or later, so they are
  rejected at plan time with `redis_version = "REDIS_3_2"`. See the matching
  "Changed" entry for the new default.
- `db_postgresdb_ssl_reject_unauthorized` lets n8n validate the PostgreSQL
  server's certificate (`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=true`) on the
  external PostgreSQL path (`create_postgres_instance = false`) instead of
  the previously hardcoded `false`, which encrypted the connection but never
  validated it. Restricted to the external path: the module connects to its
  own Cloud SQL instance by private IP, and Google documents Cloud SQL
  hostname verification only by DNS name, so n8n's hostname check is
  expected to fail there; see
  [`docs/postgresql-tls.md`](./docs/postgresql-tls.md) for the full
  explanation and limits.
- `db_postgresdb_ssl_ca_pem` takes the PEM-encoded CA bundle to trust for
  that verification (same input name as terraform-aws-n8n). The module
  passes it, whitespace-trimmed, to the n8n chart's `database.ssl.ca`, which
  the chart renders as `DB_POSTGRESDB_SSL_CA` for the main, worker, and
  webhook-processor pods. Because the CA is part of the Helm release, a CA
  change rolls the pods; if a failed upgrade's atomic rollback succeeds, the
  previous CA is restored (the design of terraform-azurerm-n8n and
  terraform-aws-n8n#178). Two new `check` warnings cover a CA that is
  ignored because verification is off, and `NODE_TLS_REJECT_UNAUTHORIZED=0`
  in an extra env input turning verification off when no CA is supplied.
- `postgres_ssl_mode` lets the module-managed Cloud SQL instance reject
  unencrypted connections outright (`ip_configuration.ssl_mode =
  ENCRYPTED_ONLY`) instead of the previously hardcoded
  `ALLOW_UNENCRYPTED_AND_ENCRYPTED`. Default is unchanged, so existing
  deployments see no plan diff.
- A new opt-in input `postgres_connection_budget_check_enabled` (default
  `false`) gates a plan-time advisory
  `check.postgres_pool_size_fits_known_max_connections` (`checks.tf`) that
  warns when `db_postgresdb_pool_size` times the modeled main, worker
  (including `n8n_worker_keda_paused_replica_count` while paused),
  webhook-processor, and `n8n_worker_pools` replica ceilings would exceed
  the default `max_connections` Cloud SQL sets for the selected
  `postgres_machine_type`, derived from
  [Google's published memory-to-`max_connections` table](https://cloud.google.com/sql/docs/postgres/flags).
  `db-f1-micro` and `db-g1-small` match directly, `db-custom-<vcpus>-<memory_mb>`
  shapes derive memory from the name, and `db-perf-optimized-N-<vcpus>`
  shapes use Google's N2 memory table. It stays silent for other shapes (for
  example `db-perf-optimized-C4-*` or `db-c4a-highmem-*`) or when
  `create_postgres_instance = false`. Off by default because the module's
  own default autoscaler ceilings (main 20 + worker 10 + webhook 50 = 80
  pods) at the default `db_postgresdb_pool_size = 10` already request 800
  connections, far over `db-g1-small`'s default `max_connections` of 50.
  Enable it once you have settled on replica ceilings and a
  `postgres_machine_type` to catch a later regression. It is an optimistic,
  advisory threshold and never fails the plan: it does not subtract reserved
  superuser slots, other clients, or extra pods during a rolling update. Fix
  a warning with one of: lower `db_postgresdb_pool_size`; lower the replica
  ceilings the check counts (the main/worker/webhook-processor autoscaler
  maxima, the fixed replica count of any role whose autoscaler is disabled,
  `n8n_worker_keda_paused_replica_count` while paused, or any
  `n8n_worker_pools` `max_replicas`); or move to a larger
  `postgres_machine_type`. The model assumes n8n connects directly to Cloud
  SQL, so leave the check off behind a connection pooler such as PgBouncer. A cheaper
  single-main sandbox profile built from existing inputs that fits under 50
  connections, and recommends enabling this check, is documented in the new
  [`docs/sandbox.md`](./docs/sandbox.md).
- Optional GKE application-layer secrets encryption (etcd) with a Cloud KMS
  key (`create_gke_kms_key`, `existing_gke_kms_key_id`), following the same
  create-or-reference contract and shared key ring as Cloud SQL, Memorystore,
  and GCS (`create_kms_key_ring`/`existing_kms_key_ring_id`). The module
  grants the GKE service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter`
  on a module-created key only. Gated on `create_gke = true`. Enabling it on
  an existing cluster restarts the control plane while GKE re-encrypts every
  Secret. Clearing both inputs later does not decrypt the cluster; see
  [Turning GKE secrets encryption off](./docs/destroy-cleanup.md#turning-gke-secrets-encryption-off).
  The new `gke_kms_key_id` output reports the key the module configures.
- Optional GKE Secret Manager CSI driver add-on
  (`gke_secret_manager_addon_enabled`), letting pods mount Google Secret
  Manager secrets as files through a caller-owned `SecretProviderClass`. The
  add-on does not sync secrets into Kubernetes Secrets, so it does not
  populate the Secrets the `*_secret_ref` inputs read. The module grants no
  Secret Manager IAM for it. Setting the input back to `false` disables the
  add-on. The module now always sets the add-on state, so on a
  module-managed cluster where someone enabled the add-on outside Terraform,
  the next plan disables it unless you set this input to `true`. Gated on
  `create_gke = true`.
- Two independently opt-in GKE network/identity hardening inputs, both
  defaulting to the module's current behavior so an existing caller sees no
  plan diff. Both take effect only when `create_gke = true`; otherwise they
  are ignored with a warning (a malformed `gke_security_group` still fails
  validation).
  - `gke_enable_private_endpoint` removes the public GKE control-plane
    endpoint. It is validated to require `gke_enable_private_nodes = true`
    and a non-empty `gke_control_plane_authorized_networks` restricted to
    internal RFC 1918 CIDRs. It updates the cluster in place; see
    [Switching an existing deployment to the private endpoint](./docs/post-deployment.md#switching-an-existing-deployment-to-the-private-endpoint).
    In this mode the `kubectl_config_command` output adds `--internal-ip`.
  - `gke_security_group` opts into GKE's Google Groups RBAC feature
    (`authenticator_groups_config.security_group`), validated as
    `gke-security-groups@<domain>`. Enabling it is one-way: setting it back
    to `null` does not disable the feature on the cluster.
- `postgres_password_write_only`, `postgres_password_wo`, and
  `postgres_password_wo_version` let the module-managed Cloud SQL
  PostgreSQL user (`create_postgres_instance = true`) accept its password
  through `google_sql_user.n8n`'s write-only `password_wo` argument instead
  of a `random_password` resource whose result Terraform stores in plain
  text in state. `postgres_password_wo` is an `ephemeral` module variable,
  so this module never writes the value to a plan or state file. That holds
  end to end only if your root module passes an ephemeral value too (an
  ephemeral input variable or an ephemeral resource); an ordinary root
  variable is saved in your plan file, and an ordinary data source stores
  the secret in your state. Empty or whitespace-only values are rejected.
  This mode requires `n8n_database_password_secret_ref`, under a name other
  than the module-managed `n8n-enterprise-db-secret` (the module cannot copy
  a write-only value into the Kubernetes Secret it would otherwise manage),
  makes the `n8n_database_password` output `null`, and is fully opt-in: the
  default (`postgres_password_write_only = false`) behavior is unchanged.
  The first plan after upgrading shows one in-place update to
  `google_sql_user.n8n` with no visible attribute changes, because Terraform
  records the new `password_wo` argument as sensitive even when it is
  `null`; the apply makes no Cloud SQL API call and the next plan is clean.
  `n8n_database_password_secret_ref` now also rejects an empty or
  whitespace-only `name` on every path; such a reference never worked,
  because the module passes the name straight to the chart.
  See [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md) for the full
  contract, including rotation (Ports
  [n8n-io/terraform-azurerm-n8n#45](https://github.com/n8n-io/terraform-azurerm-n8n/pull/45)).

### Changed

- **Provider floor raised:** `hashicorp/google` and `hashicorp/google-beta`
  now require `~> 6.23` (was `~> 6.0`). Two features need it:
  `google_container_cluster.secret_manager_config` does not exist in 6.0.x
  (Terraform rejects the block at validate time even when the add-on is
  off), and `google_sql_user`'s `password_wo`/`password_wo_version`
  (`postgres_password_write_only`) do not exist before 6.23.0.
  `google-beta` uses neither; it moves because the module keeps it in
  lockstep with `google` (`docs/versioning.md`). The examples that call the
  root module now declare `~> 6.23` too;
  `modules/controllers/examples/direct-use` stays on `~> 6.0` because the
  controllers submodule needs neither feature. This is a minor-version change
  under the module's stability contract.
  Upgrade note: if your dependency lock file selects a 6.0.x release, run
  `terraform init -upgrade` before planning. If your root module pins either
  provider to 6.0.x, widen the constraint first. The floor change itself
  changes no resources, but `terraform init -upgrade` can also move other
  providers in your root module, so review the lock file diff and the plan
  before you apply.
- Default `n8n_chart_version` bumped to `1.14.0` (was `1.13.0`; n8n-hosting
  v1.14.0, 2026-09-30, which bundles n8n `2.41.4` as its `appVersion`, so a
  caller with `n8n_image_tag = null` moves from n8n `2.40.5` to `2.41.4`; n8n
  2.41.x lists no breaking changes). No replica, KEDA, or task-runner template
  changes (`deployment-*.yaml` untouched), so the worker-only task-runner
  capacity rule (`local.n8n_chart_has_worker_only_runners`) now also covers
  `1.14.0`. Upstream changes that reach this module:
  - The chart no longer renders `N8N_AVAILABLE_BINARY_DATA_MODES`
    (n8n-hosting#185; n8n deprecated it and logs a warning whenever it is
    set) and dropped `s3.storage.availableModes` from its schema. The module
    stops sending `availableModes`, so on chart `1.14.0` the deprecated
    variable is not set on any pod and its warning is gone. **The module now
    requires n8n 2.0 or newer.** n8n 2.x ignores the variable, but n8n 1.x
    reads it and defaults to `filesystem` only, so a 1.x image on chart
    `1.14.0` would silently store binary data on each pod's own disk instead
    of GCS. Upgrade a 1.x pin to 2.x before taking this release. A chart
    pinned below `1.14.0` still renders the variable from its own default
    (`"filesystem"`), which n8n 2.x ignores.
  - The module no longer sends the deprecated `WEBHOOK_URL` to images that
    are provably n8n `2.30.0` or newer (the first release that reads
    `N8N_WEBHOOK_URL` and the first that warns about `WEBHOOK_URL` on every
    start). `N8N_WEBHOOK_URL` carries the same value. Older images build
    webhook URLs from `WEBHOOK_URL` only and fall back to
    `http://<n8n_fqdn>:5678/` without it, so the module keeps sending both
    names unless the tags prove the image is current: a versioned
    `n8n_image_tag` (or, for a custom image whose tag is not a version and
    with task runners enabled, `n8n_task_runner_image_tag`) of `2.30.0` or
    newer, or a null tag on the default chart repository at chart `1.12.0`
    or newer (`local.n8n_needs_legacy_webhook_url_env`). A tag only counts
    as versioned with a full numeric `MAJOR.MINOR.PATCH` prefix, so a custom
    tag such as `2.30.mypackages` proves nothing. Floating tags
    (`stable`, `latest`), a null tag on a private chart mirror, and a
    custom image whose tags carry no version still get `WEBHOOK_URL`. Every
    n8n pod rolls once on apply because the env list changes. Ported from
    terraform-aws-n8n#160.
  - `n8n_extra_env`, `n8n_worker_extra_env`, and
    `n8n_worker_pools[*].extra_env` now reject both
    `N8N_AVAILABLE_BINARY_DATA_MODES` and `WEBHOOK_URL` through a dedicated
    deprecated-variable rule (`local.n8n_deprecated_env_names`) instead of
    the module-managed list, so the error says to remove the entry. Both
    names were already rejected, so no previously accepted configuration is
    rejected now; only the message changes.
  - The chart's ConfigMap now emits `N8N_WEBHOOK_URL` instead of
    `WEBHOOK_URL` (n8n-hosting#184, missing from the upstream release
    notes). No effect here: the chart only emits it from its own
    `webhook.url` or `ingress` values, and the module sets neither.
    `tests/scripts/check-n8n-chart.sh` now fails if the chart renders the
    legacy `WEBHOOK_URL` itself, or renders
    `N8N_AVAILABLE_BINARY_DATA_MODES` (after confirming the S3 env block
    rendered, so the check cannot pass vacuously).
  - The chart's own values validation now reports every failure in one
    render instead of stopping at the first (n8n-hosting#209).
  - See `docs/upgrading-n8n.md`, "Moving from chart 1.13.0 to 1.14.0".
- **Changed default:** `redis_maxmemory_policy` (default `"noeviction"`) now
  sets `redis_configs["maxmemory-policy"]` on the module-managed Memorystore
  instance, replacing Memorystore's own `volatile-lru` default. Under memory
  pressure, `volatile-lru` evicts keys that carry a TTL. These include Bull's
  per-job lock keys, so an in-flight n8n execution can lose its lock and fail
  as stalled. `noeviction` instead rejects writes once the instance is full.
  This is an in-place configuration update with no instance restart, but it
  overwrites any `maxmemory-policy` set outside Terraform; see
  [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md#memorystore-maxmemory-policy-now-defaults-to-noeviction).
- **Breaking:** `required_version` is now `>= 1.11` (was `>= 1.9`).
  The `ephemeral` variable `postgres_password_wo` needs Terraform 1.10, and
  passing it to the write-only `password_wo` argument needs 1.11 (see
  "Added" above). The floor applies module-wide regardless of whether you
  set that variable, because Terraform parses `ephemeral` and write-only
  syntax from this module's HCL unconditionally. The `modules/controllers`
  submodule keeps `>= 1.9`. Upgrade the Terraform CLI, and run
  `terraform init -upgrade` for the provider floor above, before applying;
  see
  [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md#terraform-cli-floor-raised-to--111)
  (Ports
  [n8n-io/terraform-azurerm-n8n#45](https://github.com/n8n-io/terraform-azurerm-n8n/pull/45)).

## [0.1.0] - 2026-09-29

Initial release. Nothing was tagged before this version. The pre-release
development history, including every intermediate rename and breaking change
made on `main`, is preserved in the
[pre-release `CHANGELOG.md`](https://github.com/n8n-io/terraform-google-n8n/blob/2a364954f8323942fa67874a3a1e67f4e6f2d90d/CHANGELOG.md).

### Added

- Production-grade, multi-main n8n Enterprise deployment in queue mode on
  Google Kubernetes Engine (GKE): dedicated main, worker, and webhook-processor
  pods, fronted by a native GKE Ingress (Google Cloud L7 load balancer).
  Requires an n8n Enterprise license for multi-main.
- **Explicit, per-layer ownership model.** Network/PSA, GKE, Cloud SQL,
  Memorystore Redis, the GCS bucket, the Kubernetes namespace, and ingress
  each have a `create_*` switch, and every autoscaler (HPA/KEDA) has its own
  `*_enabled` switch, so the module can own a layer end-to-end or attach to a
  caller-managed equivalent independently per layer. See
  [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md)
  for the full ownership/security-boundary matrix.
- 11 runnable example roots: `small`, `medium`, `large` (sizing tiers),
  `cloudflare` and `godaddy` (DNS-provider variants), `split-ingress`
  (public/private route isolation), `customer-managed-cluster`,
  `customer-managed-redis`, `customer-managed-gcs`, and
  `customer-managed-everything` (ownership-boundary variants), and
  `worker-pools` (**EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE**, tracks
  an unreleased upstream n8n/chart preview feature).
- Regional, VPC-native GKE cluster with a managed, autoscaled node pool, a
  dedicated least-privilege node service account, GKE Dataplane V2, Shielded
  nodes, and Workload Identity so pods authenticate to Google Cloud APIs
  without static keys. `create_gke = false` attaches to an existing cluster
  instead.
- Public `modules/controllers` submodule: the KEDA Helm release and an
  optional pd-balanced `StorageClass` behind a typed, validated contract,
  independently consumable (see `modules/controllers/examples/direct-use`).
- Cloud SQL for PostgreSQL over Private Service Access, with restore/clone
  support, configurable backup and transaction-log retention, optional query
  logging, and an explicit Cloud KMS create-or-reference CMEK key. External
  PostgreSQL is supported via `create_postgres_instance = false`.
- Memorystore for Redis over Private Service Access, with optional AUTH, TLS
  in transit (trusted end-to-end by n8n and KEDA), opt-in RDB persistence, an
  opt-in private Redis-metrics exporter, and its own CMEK key. External
  Redis-compatible services are supported via `create_redis_instance = false`.
- Google Cloud Storage bucket for n8n binary data, reached through the
  S3-compatible driver via an HMAC key, with CMEK, public-access prevention, a
  noncurrent-version lifecycle rule, and a dedicated access-log bucket. A
  bring-your-own bucket is supported via `create_gcs_bucket = false`; HMAC
  identity ownership is a separate, independent switch and works with either
  a module-managed or a bring-your-own bucket.
- KEDA-based worker autoscaling on Redis/Bull queue depth, including
  per-pool scaling for the EARLY ALPHA `n8n_worker_pools` feature, plus an
  HPA for main and webhook-processor pods. `n8n_worker_keda_pause` and
  `n8n_worker_keda_paused_replica_count` pause autoscaling of the default
  worker Deployment only; worker pools keep scaling.
- Google Secret Manager access for n8n's own External Secrets feature, scoped
  to a caller-declared secret allow-list.
- TLS via `tls_mode`: `google_managed` (default, `ManagedCertificate`),
  `secret` (existing Kubernetes TLS secret, e.g. cert-manager), `custom`
  (bring-your-own PEM), and `self_signed`; optional Cloud DNS A-record
  management or bring-your-own DNS; multi-hostname coverage via
  `n8n_additional_domains`; an optional module-managed Cloud Armor security
  policy (including the Log4Shell/CVE-2021-44228 canary rule) or an existing
  policy reference; and an optional ingress SSL policy.
- A wide n8n runtime-configuration surface: custom n8n/task-runner images and
  pull secrets, extra volumes/env, a credentials-overwrite Secret reference, a
  custom task-runner launcher-config ConfigMap reference, community-package
  registry/security controls, pod-level DNS config, graceful-shutdown timeout,
  execution-data storage mode (`database` or `s3`), and license delivery via a
  direct key or an existing Secret reference.
- A non-blocking managed-GKE capacity guardrail (`capacity.tf`/`checks.tf`)
  that warns, at plan time, when configured replica maxima across main,
  worker, and webhook-processor pods could exceed the node pool's estimated
  allocatable CPU/memory.
- A curated Checkov security baseline: CMEK key rotation, Cloud SQL audit
  logging flags, VPC Flow Logs plus an explicit deny-all-ingress firewall
  rule, and GKE Dataplane V2/Shielded-node/no-client-certificate
  hardening, with CI running Checkov `soft_fail: false` (hard gate) plus a
  second opt-in pass (`tests/checkov/opt-in.tfvars`) that enables the
  default-off Redis exporter, which a default-tfvars scan cannot evaluate.
  The opt-in pass runs with `--skip-path examples` and accepts only exact
  root-module addresses as proof that it evaluated the exporter Deployment
  and Service. Against Checkov `3.3.20`, the default pass reports 111
  passed, 0 failed, and 189 skipped checks, and the opt-in pass reports 0
  failed checks.
- Plan-time `terraform test` suites at the module root, in every example, and
  in `modules/controllers`, using mocked providers so they run offline with no
  Google Cloud credentials, plus a credential-free n8n Helm chart rendering
  regression check (`tests/scripts/check-n8n-chart.sh`).
- A post-apply smoke test (`tests/scripts/smoke-test.sh`) for live
  deployments. It checks the queue-mode topology the module always deploys,
  fails when the `n8n-worker` Deployment is absent, and asserts the
  single-main safeguards when one main replica is selected: a main HPA
  pinned to one replica (or one fixed replica when
  `n8n_main_hpa_enabled = false`), the `Recreate` strategy, and PDB
  `minAvailable = 0`.
- Contributor tooling: `CONTRIBUTORS`, a `.github/CODEOWNERS` header, a
  `Taskfile.yml` that wraps the local check loop (`task ci`) across the
  module root, every example, and `modules/controllers`, and
  `scripts/check-variable-banners.sh` (`task banners`), which verifies every
  `variable` and `output` block sits under its documented `# ── Section ──`
  banner.
- Governance and operations docs: `docs/versioning.md` (every pinned version,
  its bump tier, and a weekly automated drift report), `docs/upgrading-n8n.md`,
  `docs/manual-verification-checklist.md`, `docs/customer-managed-infrastructure.md`,
  `docs/troubleshooting.md`, `docs/destroy-cleanup.md`, `docs/post-deployment.md`,
  `docs/istio-ingress.md`, `docs/helm-chart-coverage.md`, and `ROADMAP.md`.

### Compatibility

- **Terraform CLI:** `>= 1.9`. CI runs the pinned version listed in
  [`docs/versioning.md`](./docs/versioning.md).
- **`google` and `google-beta` providers:** `~> 6.0`.
- **`kubernetes` provider:** `~> 3.0`.
- **`helm` provider:** `~> 3.0`.
- **`kubectl` provider (`gavinbunney/kubectl`):** `~> 1.14`.
- **`tls` provider:** `~> 4.0`. **`random` provider:** `~> 3.0`. **`time`
  provider:** `~> 0.14`.
- **n8n Helm chart:** `1.13.0` default (n8n `2.40.5`). **KEDA Helm chart:**
  `2.20.1` default. See [`docs/versioning.md`](./docs/versioning.md) for the
  complete pin inventory.
- **Validated on:** a recent GKE `REGULAR` release channel version and Cloud
  SQL `POSTGRES_16`.
- **CI toolchain:** Checkov `3.3.20` (`bridgecrewio/checkov-action@v12.3126.0`)
  and TFLint `v0.64.0`.

### Known limitations

- This module is preliminary and not scale-validated (no load test). Expect
  breaking changes in `0.x` minor releases, as described in
  [README.md, Stability & versioning](./README.md#stability--versioning).
- `kubernetes_namespace` and several `kubernetes_secret` resources still use
  the unversioned resource types, so they plan with a cosmetic "Deprecated
  Resource" warning under `kubernetes` provider 3.x. They are not renamed to
  their `_v1` equivalents because the provider has no `moved` support across
  that rename (`hashicorp/terraform-provider-kubernetes` issue #2812), and a
  rename would destroy and recreate the namespace. If your root module
  constrains `kubernetes` to `~> 2.0`, widen it first, or `terraform init`
  cannot satisfy both constraints.
- See [README.md → Out of scope](./README.md#out-of-scope) for what this
  release explicitly does not cover.
- `n8n_worker_pools` is **EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE**: it
  tracks an n8n feature and a chart preview build that are themselves
  unreleased upstream (see the `worker-pools` example's README).
- [`docs/manual-verification-checklist.md`](./docs/manual-verification-checklist.md)
  lists 15 runtime-only scenarios (topology transitions, credential/config
  rotation restarts, restore/clone key continuity, TLS/DNS alias coverage,
  the Redis command-prefix transition, Memorystore RDB recovery, and license
  entitlement boundaries) that mocked `terraform test` cannot exercise.
  Several were run live against disposable `examples/small` deployments
  (recorded in that document); the rest are tracked there as not yet run.

[Unreleased]: https://github.com/n8n-io/terraform-google-n8n/compare/0.1.0...HEAD
[0.1.0]: https://github.com/n8n-io/terraform-google-n8n/releases/tag/0.1.0
