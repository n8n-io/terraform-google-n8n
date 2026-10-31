# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md, Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Added

- `n8n_webhook_pdb_enabled` and `n8n_worker_pdb_enabled` (both default
  `true`) create PodDisruptionBudgets with `maxUnavailable = 1` for the
  webhook processor and default worker Deployments. The n8n chart renders a
  budget for the main pods only, so a GKE node-pool upgrade or other drain
  could stop every webhook processor and every worker at once. Uses
  `maxUnavailable` rather than `minAvailable` so a one-replica Deployment
  never blocks a drain, which also means each budget protects nothing until
  its Deployment runs two or more pods. `n8n_worker_pools` Deployments are
  not covered.
  Existing deployments gain both budgets on the next apply (two new
  resources). Ports terraform-aws-n8n#205.

  **Upgrade note:** before upgrading, run
  `kubectl get pdb -n <namespace> -o yaml` (namespace `n8n` unless you
  changed `n8n_kube_namespace`) and compare each budget's `spec.selector`
  with the labels of the webhook processor and worker pods. If a budget you
  already own selects those pods, set the matching `n8n_webhook_pdb_enabled`
  or `n8n_worker_pdb_enabled` to `false` and keep your own budget. When two
  budgets select the same pod, the Eviction API rejects every eviction of it,
  so `kubectl drain` and cluster autoscaler scale-down fail, and GKE
  node-pool surge upgrades stall until GKE's one-hour drain timeout forces
  the eviction (blue-green upgrades use their own timeouts). If a budget you own is
  named `n8n-webhook-processor` or `n8n-worker`, the apply fails with
  "already exists"; set the matching input to `false` as well. See
  `docs/upgrading-n8n.md`, "Moving from chart 1.15.0 to 1.16.0".

- `google_partner_attribution_label` sets the `goog-partner-solution` label,
  Google Cloud's partner consumption tracking label for Cloud Marketplace
  products. Prepared ahead of end-to-end testing: it defaults to empty
  (nothing is added) because n8n's Marketplace consumption tracking label,
  shown in Producer Portal, has not been agreed for use here yet; the default
  changes to that value once it is. Set, it reaches the module-managed
  resources that accept labels through `local.gcp_labels`, the
  module-managed GKE node VMs through `node_config.resource_labels` (GKE also
  propagates cluster labels to node VMs and attached disks, but only through
  an hourly background process; with `create_gke = false` the existing node
  pools are unchanged), the n8n main, worker and webhook-processor pod
  templates through the chart's `podLabels`, the Redis exporter pods, and
  disks provisioned through the module's pd-balanced StorageClass through a
  new `modules/controllers` input, `pd_disk_labels` (the PD CSI driver's
  `labels` parameter), also exposed as the new `modules/controllers` output
  `pd_balanced_storage_class_parameters`. The input owns the label: a
  `goog-partner-solution` key in `common_labels` is now ignored, whether or
  not the input is set, matching terraform-aws-n8n's `aws-apn-id` handling.
  Not labeled by Terraform: resources GKE creates outside Terraform for the
  Ingress (forwarding rules, backend services), and resources without a label
  argument (VPC, subnet, router, NAT, firewall). Upgrade note: at the default
  nothing changes, unless `common_labels` already contains
  `goog-partner-solution`, in which case that label is removed from the
  labeled resources, including the module node pool's Kubernetes node
  `labels`, which GKE applies by recreating the nodes (move the value to
  `google_partner_attribution_label` to keep it). Setting, changing or clearing the input with
  `create_gke = true` updates the node pool in place (its `resource_labels`
  and Kubernetes node `labels`), which GKE applies by recreating the nodes
  without respecting maintenance policies; it also rolls the n8n and Redis
  exporter pods, and replaces the pd-balanced StorageClass because its
  parameters are immutable (bound volumes keep working; disks already
  provisioned are not relabeled through the StorageClass).
  `google_container_cluster.n8n` ignores changes to its leftover default-pool
  `node_config.resource_labels`: GKE reports the module node pool's labels
  there, so the cluster would otherwise plan to strip the partner label on
  every run, and applying that fails with `Node pool "default-pool" not found
  on update`. A deployment that applied the label with an earlier commit of
  this change needs this fix before it can clear the label. After the label
  is cleared, Terraform state can still show it under the cluster's
  `node_config.resource_labels` while the live cluster is already clean:
  the cluster is updated and read back before the node pool update removes
  the label in GKE. The next plan shows this only as a refresh change with
  no planned actions, and the next apply saves the refreshed state.

- `n8n_extra_ca_pem`: trust a private or TLS-intercepting-proxy CA for
  n8n's outbound TLS. The module stores the PEM in a module-managed Secret,
  mounts it read-only at `/etc/n8n-certs/ca-bundle.crt` on the main, worker,
  and webhook-processor pods, and sets `NODE_EXTRA_CA_CERTS` to it. Node reads
  one file, so when `redis_transit_encryption_enabled = true` the Secret holds
  the Memorystore CA followed by the supplied PEM. Proxy routing itself
  (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`) stays in `n8n_extra_env`.
  `NODE_EXTRA_CA_CERTS` remains reserved against `n8n_extra_env`. A
  `checksum/extra-ca` pod annotation (sha256 of the bundle) rolls the three
  deployments when the CA changes. Setting it back to `null` deletes the
  Secret before Helm rolls the pods; `docs/tls-proxy.md` covers the effect on
  pods scheduled during the rollout and on a failed upgrade. The task-runner
  sidecar is not covered; see `docs/tls-proxy.md`.
- `n8n_proxy_hops`: sets `N8N_PROXY_HOPS` on every role for an inbound
  reverse proxy, WAF, or CDN in front of the ingress. The Google load balancer
  adds two `X-Forwarded-For` entries, so it counts as 2: the module-managed
  ingress alone is 2, and one customer proxy in front of it is 3. Without it
  n8n logs `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` and does not see the real
  client address. The count is only safe when every path to n8n crosses the
  same number of proxies; see `docs/tls-proxy.md`. Defaults to `null` (not
  set), unlike `terraform-aws-n8n` and `terraform-azurerm-n8n`, which default
  to 1: existing deployments do not change, and `N8N_PROXY_HOPS` stays usable
  through the extra-env inputs. It is reserved against `n8n_extra_env`,
  `n8n_worker_extra_env`, and pool `extra_env` only while this is set.
- `docs/tls-proxy.md`: outbound, inbound, and combined proxy setups, with the
  task-runner sidecar limitation.
- `docs/reference/task-runner-custom-ca/`: a live-proven reference for making
  the task-runner sidecar's JavaScript runner trust a private/proxy CA with a
  custom runner image (`n8n_task_runner_image_repository` /
  `n8n_task_runner_image_tag`) and a matching launcher configuration
  (`n8n_task_runner_custom_config`) that sets `NODE_EXTRA_CA_CERTS`. Includes a
  Dockerfile, production and verification launcher configs, a Terraform
  snippet, and a verification script. The Python runner is not covered.
- Every example now exposes `n8n_extra_ca_pem`, `n8n_proxy_hops`, and
  `n8n_extra_env` as passthrough variables, so a TLS-inspecting egress proxy or
  a proxy in front of the ingress can be used from any of them.
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

- `n8n_license_cert_secret_ref` supports offline license activation
  (`N8N_LICENSE_CERT`) for air-gapped or egress-restricted clusters that
  cannot reach n8n's license server. It is mutually exclusive with
  `n8n_license_key` and `n8n_license_key_secret_ref` - exactly one of the
  three must be set. The certificate renders through the shared
  `config.extraEnv` list as a `secretKeyRef`, not through the chart's
  `license.existingSecret` block, which only ever maps to
  `N8N_LICENSE_ACTIVATION_KEY`; `existingSecret` is omitted on this path.
  `license.enabled` stays `true` on this path because the chart also gates
  `N8N_MULTI_MAIN_SETUP_ENABLED` on `license.enabled`, not on which
  credential backs it. `name` and `key` are validated as a Kubernetes Secret
  name (DNS-1123 subdomain) and data key respectively, not just checked for
  non-blank. While the input is set, `n8n_extra_env`,
  `n8n_worker_extra_env`, and `n8n_worker_pools[*].extra_env` reject
  `N8N_LICENSE_CERT`; while it is null they accept it as before, so no
  existing configuration is rejected. `examples/small` passes the input
  through, treating its empty `n8n_license_key` default as unset on this
  path. See ["Offline license
  activation"](./README.md#offline-license-activation), which also covers
  matching the certificate to the instance ID and switching back to a key.
  The certificate covers initial activation only: a fully offline deployment
  should set `N8N_LICENSE_AUTO_RENEW_ENABLED=false` through `n8n_extra_env`,
  block egress to n8n's license server, and request a replacement
  certificate before the current one expires (see ["Offline license
  activation"](./docs/post-deployment.md#offline-license-activation) in
  `docs/post-deployment.md`). Same design as
  [terraform-aws-n8n#171](https://github.com/n8n-io/terraform-aws-n8n/pull/171)
  and
  [terraform-azurerm-n8n#51](https://github.com/n8n-io/terraform-azurerm-n8n/pull/51).

### Changed

- **Provider floor raised (breaking):** `hashicorp/google` and
  `hashicorp/google-beta` now require `~> 8.0` (was `~> 6.0` in 0.1.0). The
  module still needs two features from 6.x: `google_sql_user`'s
  `password_wo`/`password_wo_version` (`postgres_password_write_only`, from
  6.23.0) and `google_container_cluster.secret_manager_config` (from 6.1).
  Both exist in 8.x. `google-beta` uses neither; it moves because the module
  keeps it in lockstep with `google` (`docs/versioning.md`). The examples
  that call the root module declare `~> 8.0` too;
  `modules/controllers/examples/direct-use` stays on `~> 6.0` because the
  controllers submodule needs neither feature. This is a minor-version change
  under the module's stability contract. The provider major was checked
  against the 7.0 and 8.0 upgrade guides: their entries for resources this
  module creates (`google_compute_router`, `google_compute_subnetwork`,
  `google_sql_user`, `google_storage_bucket`, `google_container_cluster`,
  `google_container_node_pool`) need no configuration change. See
  `docs/upgrading-n8n.md`, "Google provider floor raised to ~> 8.0", for
  what to expect on the first plan.
  Rollback: back up your state, in encrypted storage, before 8.x first
  writes it. Any apply on 8.x writes state, even one that plans no changes.
  Provider 8.x writes some resources (for example `google_storage_bucket`)
  at a newer state schema version that 6.x cannot read, so after that,
  reverting the provider constraint alone does not roll
  back.
  Known warning: from provider 8.9.0, `google_container_cluster`'s
  `remove_default_node_pool` is deprecated, so `terraform validate` and
  `terraform plan` print a deprecation warning. The argument still works; the
  suggested replacement needs GKE 1.36.4-gke.1469000 or later.
  Upgrade note: if your dependency lock file selects a 6.x release, run
  `terraform init -upgrade` before planning. If your root module pins either
  provider below 8.0, widen the constraint first. `terraform init -upgrade`
  can also move other providers in your root module, so review the lock
  file diff and the plan before you apply. If you set
  `psa_connection_abandon_on_destroy = false`, the first plan may show a
  one-time in-place update of `google_service_networking_connection.psa` to
  `deletion_policy = "DELETE"`; see `docs/upgrading-n8n.md`.
- `private_cluster_config.enable_private_nodes` itself is no longer
  `ForceNew` under provider 8.x. The module derives the `ForceNew`
  `master_ipv4_cidr_block` from `gke_enable_private_nodes` (`gke.tf`), so
  turning private nodes on plans a cluster replacement when the configured
  control-plane CIDR differs from the value in state. Turning them off sets
  that field to `null`, which keeps the stored value because the field is
  also `Computed`, so it is expected to plan as an in-place update. Neither
  direction was verified against a real cluster. `docs/build-time-decisions.md`'s
  row now describes both directions.
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
- Default `keda_chart_version` bumped to `2.21.0` (was `2.20.1`; KEDA
  v2.21.0), in the root module and `modules/controllers`. This is a security
  fix (see Security below). KEDA 2.21 lists three breaking changes
  (service-account-token audience enforcement for Vault and
  `boundServiceAccountToken` authentication, Azure Pipelines in-flight jobs,
  removed Temporal scaler settings); none applies to the module, whose
  `TriggerAuthentication` uses only `secretTargetRef` and which uses neither
  scaler. With `install_keda = true` (the default), a caller that does not
  pin `keda_chart_version` gets an in-place Helm upgrade on the next apply,
  and the KEDA operator pods roll once; nothing in the n8n namespace is
  replaced. The move also picks up KEDA 2.20.2, which reports HPA health in
  a new `HPAActive` `ScaledObject` condition instead of `Ready`;
  `tests/scripts/smoke-test.sh` now reads it too. KEDA 2.21 is tested on
  Kubernetes v1.34 to v1.36 (2.20: v1.33 to v1.35). On 2026-10-13 that
  covered every version GKE's `REGULAR` and `STABLE` channels offered; GKE's
  release schedule (checked 2026-10-29) lists 1.37 on `RAPID` since
  2026-09-02 and on `REGULAR` since 2026-10-22, so check your cluster's
  version. Verified live on `examples/small` (GKE 1.36.4, `REGULAR`): the
  in-place upgrade from `2.20.1` planned only the KEDA release change; after
  apply the `ScaledObject` stayed `Ready=True` and `HPAActive=True`, the smoke
  test with `LOAD_TEST=true` passed with Redis AUTH both off and on (turning
  AUTH on for an existing instance needed a second apply, a separate bug fixed
  in #54), the re-plan was clean, and a rollback to `2.20.1` was also a clean
  in-place update. See `docs/upgrading-n8n.md`, "Moving from KEDA chart 2.20.1 to
  2.21.0".
- Default `n8n_chart_version` bumped to `1.15.0` (was `1.14.0`; n8n-hosting
  v1.15.0, which bundles n8n `2.42.4` as its `appVersion`, so a caller with
  `n8n_image_tag = null` moves from n8n `2.41.4` to `2.42.4`; the n8n release
  notes for 2.42.0 through 2.42.4 list no breaking changes). No replica, KEDA,
  or task-runner template changes (`deployment-*.yaml` untouched), so the
  worker-only task-runner capacity rule (`local.n8n_chart_has_worker_only_runners`)
  now also covers `1.15.0`. Upstream changes that reach this module:
  - The chart now renders `DB_POSTGRESDB_SSL_ENABLED` from
    `database.ssl.enabled` instead of `DB_POSTGRESDB_SSL`, which n8n does not
    read (n8n-hosting#175). The module sets `database.ssl.enabled` only for
    `db_postgresdb_ssl_ca_pem` with `db_postgresdb_ssl_reject_unauthorized = true`;
    there, on the upstream repository at a released chart `1.15.0` or newer,
    it now omits its own `DB_POSTGRESDB_SSL_ENABLED` extraEnv entry, so the
    variable appears once per pod instead of twice. Without a CA the behavior
    is unchanged, and older charts, prerelease chart versions (e.g.
    `1.15.0-rc.1`), and custom chart repositories keep the module's entry;
    build metadata (e.g. `1.15.0+build.5`) still counts as the release.
  - New chart values `extraObjects` and `database.ssl.existingSecret`
    (n8n-hosting#219, #222); the module sets neither.
  - See `docs/upgrading-n8n.md`, "Moving from chart 1.14.0 to 1.15.0".
- Default `n8n_chart_version` bumped to `1.16.0` (was `1.15.0`; n8n-hosting
  v1.16.0, which bundles n8n `2.43.5` as its `appVersion`, so a caller with
  `n8n_image_tag = null` moves from n8n `2.42.4` to `2.43.5`; the n8n release
  notes for 2.43.0 through 2.43.5 list no breaking changes). Upstream changes
  that reach this module:
  - `templates/deployment-main.yaml` and `templates/deployment-worker.yaml`
    changed (shared helpers for pod/container `securityContext` and the
    task-runner sidecar), but the worker-only task-runner capacity rule
    (`local.n8n_chart_has_worker_only_runners`) still applies: the sidecar's
    standalone-mode gate (`n8n.mainTaskRunnersEnabled`, n8n-hosting#179) is
    byte-for-byte unchanged, so `1.16.0` is added to that list.
  - **Multi-main guard, already satisfied.** The chart now refuses to render
    `replicaCount > 1` or `hpa.main.maxReplicas > 1` without
    `multiMain.enabled = true`, and refuses `multiMain.enabled = true`
    without `license.enabled = true` (n8n-hosting#229). The module already
    always sets `multiMain.enabled` from the same effective main-replica
    count it sets `replicaCount`/`hpa.main.maxReplicas` from, and always sets
    `license.enabled = true`, so no module change was needed; a negative
    render fixture in `tests/scripts/check-n8n-chart.sh` now proves the
    guard trips on the combinations the module never produces.
  - **The main `PodDisruptionBudget` no longer renders at one main
    replica.** Previously the chart rendered a permissive PDB
    (`minAvailable: 0`) for a single main; now it renders no PDB object at
    all unless main exceeds one replica, by `replicaCount`/
    `multiMain.replicas` or `hpa.main.minReplicas` (n8n-hosting#228). The
    module's own values are unchanged (`pdb.enabled = true`,
    `local.n8n_main_pdb_min_available`), so this only changes what the
    chart does with them: a single-main deployment now has no `n8n-main`
    PDB object to query at all, rather than one with `minAvailable: 0`.
    `tests/scripts/check-n8n-chart.sh` now asserts the PDB's absence
    instead of its `minAvailable` value in that topology (it always
    renders the one pinned chart). `tests/scripts/smoke-test.sh` checks a
    live, possibly caller-overridden deployment, so it reads the chart
    version actually deployed (the `helm.sh/chart` label on the main
    Deployment) and asserts absence only on `1.16.0` or newer, falling
    back to the old `minAvailable: 0` assertion on an older pin. If the
    label cannot be parsed, it accepts either shape and still fails on a
    more restrictive budget.
  - **Task-runner sidecar liveness probe**, enabled by default
    (`taskRunners.probes.liveness`, port 5680, path `/healthz`). The module
    sets neither `taskRunners.probes` nor
    `N8N_RUNNERS_LAUNCHER_HEALTH_CHECK_PORT`, so the chart's default applies
    unmodified; the task-runner fixture in `check-n8n-chart.sh` now also
    asserts the probe renders on the worker sidecar.
  - New values the module does not set: `editor.url` (would collide with
    the module's own `N8N_EDITOR_BASE_URL` extraEnv entry if ever set,
    n8n-hosting#243), `podSecurityContext`/`containerSecurityContext`
    per-role overrides (n8n-hosting#236), `hostAliases` (n8n-hosting#167),
    `image.digest`/`taskRunners.image.digest` (n8n-hosting#240), and
    `persistence.annotations` (n8n-hosting#240). The chart's own
    `editor.url`/`ingress.enabled`/`webhook.url` all stay unset by this
    module, so its `N8N_EDITOR_BASE_URL` ConfigMap entry stays empty and
    does not duplicate the module's own extraEnv entry.
  - See `docs/upgrading-n8n.md`, "Moving from chart 1.15.0 to 1.16.0".
- **Changed default:** `redis_maxmemory_policy` (default `"noeviction"`) now
  sets `redis_configs["maxmemory-policy"]` on the module-managed Memorystore
  instance, replacing Memorystore's own `volatile-lru` default. Under memory
  pressure, `volatile-lru` evicts keys that carry a TTL. These include Bull's
  per-job lock keys, so an in-flight n8n execution can lose its lock and fail
  as stalled. `noeviction` instead rejects writes once the instance is full.
  This is an in-place configuration update with no instance restart, but it
  overwrites any `maxmemory-policy` set outside Terraform; see
  [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md#memorystore-maxmemory-policy-now-defaults-to-noeviction).
- **Breaking:** `required_version` is now `>= 1.13` (was `>= 1.9`).
  The `ephemeral` variable `postgres_password_wo` needs Terraform 1.10, and
  passing it to the write-only `password_wo` argument needs 1.11 (see
  "Added" above). 1.13 is the floor because `terraform test` on 1.12 and
  older leaves about one provider process running per `run` block until the
  command exits (n8n-io/terraform-google-n8n#30), which 1.13.0 does not. CI
  now runs on Terraform 1.16.6 and also runs every `terraform test` suite
  on 1.13.0, so the floor stays tested. The floor applies module-wide regardless of
  whether you set that variable, because Terraform parses `ephemeral` and
  write-only syntax from this module's HCL unconditionally. The
  `modules/controllers` submodule keeps `>= 1.9`. Upgrade the Terraform CLI,
  and run `terraform init -upgrade` for the provider floor above, before
  applying; see
  [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md#terraform-cli-floor-raised-to--113)
  (Ports
  [n8n-io/terraform-azurerm-n8n#45](https://github.com/n8n-io/terraform-azurerm-n8n/pull/45)).

### Fixed

- `check.gke_capacity_cpu_fits_requested_replicas` and
  `check.gke_capacity_memory_fits_requested_replicas` now count
  `n8n_worker_keda_paused_replica_count` while `n8n_worker_keda_pause` is true
  (and the module manages the worker `ScaledObject`), via the shared
  `local.capacity_worker_modeled_max_replicas` that the PostgreSQL
  connection-budget check also uses. A paused count above
  `n8n_worker_keda_max_replicas` no longer hides an over-capacity node pool.
  Both warnings suggest lowering `n8n_worker_keda_paused_replica_count` only
  while that count is above the worker maximum. Advisory checks only; plan
  and apply are unaffected.
- `tests/scripts/check-checkov.sh` (contributor tooling, no module change)
  now removes every exported `TF_VAR_*` variable, including names with
  hyphens, before it runs checkov. On checkov 3.3.20 an exported `TF_VAR_*`
  can make checkov ignore `--var-file`, so the opt-in pass would stop
  applying `tests/checkov/opt-in.tfvars` (seen in terraform-aws-n8n#199).
  CI exports none, so its results do not change.
- `tests/scripts/check-version-drift.sh` (contributor tooling, no module
  change) now evaluates each provider constraint against the latest
  registry release instead of looking for the version number in the
  constraint text. A constraint that already accepts the latest release
  (`~> 3.0` against 3.3.0) reports `OK` instead of `DRIFT`; only a release
  outside the constraint reports `DRIFT`. A constraint the evaluator cannot
  parse (for example a prerelease constraint) reports an explicit `ERROR`.
  Prerelease registry releases are still skipped before evaluation, as
  before, so they never count as the latest release. The evaluator
  lives in `tests/scripts/lib/constraints.sh`, and the offline test
  `tests/scripts/test-version-drift-constraints.sh` runs in CI with the
  other `tests/scripts/test-*.sh` scripts.
- Module-created Cloud KMS keys for Cloud SQL, Memorystore, and GCS
  (`google_kms_crypto_key.postgres`, `.redis`, and `.gcs`) now carry the
  module's standard labels (`local.gcp_labels`, including `common_labels`),
  like the GKE secrets-encryption key (`google_kms_crypto_key.gke`) already
  does. Applying this is an in-place label update on existing keys: no key
  replacement and no re-encryption. The provider manages only the label keys
  in the configuration, so labels added outside Terraform under other keys
  are kept, but a label added outside Terraform under the same key as a
  module label (`managed_by`, `app`, `cluster`, or a `common_labels` key) is
  overwritten. Keys supplied through `existing_*_kms_key_id` are not
  touched.
- `friendly_name_prefix` now rejects values containing `google` at plan time
  when `create_gcs_bucket = true`. The module builds its GCS bucket names from
  the prefix and Cloud Storage refuses any bucket name containing `google`,
  which previously failed mid-apply after most of the stack was created. With
  `create_gcs_bucket = false` no bucket name is built from the prefix, so
  existing deployments that use `existing_gcs_bucket_name` are unaffected.
- `db_postgresdb_ssl_ca_pem` now rejects bundles over 131,050 bytes in UTF-8
  after trimming (CRLF line endings count as two bytes per line break). The
  module counts bytes, not characters, because Terraform's `length()` counts a
  multibyte character or a CRLF line break once. n8n receives the bundle as
  the single environment variable `DB_POSTGRESDB_SSL_CA`, and Linux cannot
  start a container whose single environment string exceeds 131,072 bytes
  (with 4 KiB pages), so an oversized bundle previously passed the plan and
  then failed every main, worker, and webhook-processor container with
  `argument list too long`.
- The module-created load balancer static IP
  (`google_compute_global_address.lb`) and Private Services Access range
  (`google_compute_global_address.psa`) now carry the module's standard
  labels (`local.gcp_labels`, including `common_labels`). Terraform plans this
  as an in-place label update on each address (`labels` does not force
  replacement). This was verified live on an existing `examples/small`
  deployment with Cloud SQL and Memorystore using the PSA range: the plan
  showed only the label updates on the two addresses, with no replacement of
  either address, the network, `google_service_networking_connection.psa`,
  Cloud SQL, or Memorystore. The apply succeeded, the static IP did not
  change, and n8n kept serving traffic. Reverting the change removed the
  labels in place the same way. The provider manages only the
  label keys in the configuration, so labels added outside Terraform under
  other keys are kept. A label under the same key as a module label
  (`managed_by`, `app`, `cluster`, or a `common_labels` key) is overwritten,
  whether it was added outside Terraform or through the provider's
  `default_labels`. After reverting this change and applying, keys still set
  in the provider's `default_labels` take those values again and the other
  module label keys are removed. Overwritten values that were set outside
  Terraform are not restored. The update calls the Compute Engine
  `globalAddresses.setLabels` API, so the deploying identity needs
  `compute.globalAddresses.setLabels` in the project that owns each address.
  For the PSA range on a Shared VPC (`existing_network_project_id` set), that
  is the host project.
- The prerequisite API lists in the README, the example READMEs, and
  `scripts/preflight.sh` now include `cloudresourcemanager.googleapis.com`.
  The module always reads the project (`data.google_project.n8n`) and the
  Service Networking connection looks the project up through it, so `apply`
  failed with `Cloud Resource Manager API has not been used in project ...`
  in a project that had never enabled it. They also include
  `storage.googleapis.com`, because the module always creates a bucket IAM
  binding and, by default, the GCS buckets and HMAC key.
- The README now names the project roles a deploying identity needs beyond
  `roles/editor`, each qualified by the switch that creates the resource it
  authorizes: `roles/servicenetworking.networksAdmin` (Service Networking
  peering, `create_psa = true`), `roles/iam.serviceAccountAdmin` (the
  Workload Identity binding, always), `roles/resourcemanager.projectIamAdmin`
  (the module's project IAM bindings, `create_gke` or
  `create_postgres_instance`), and `roles/container.admin` (the KEDA
  release's cluster-scoped RBAC, `install_keda`). Each missing role failed a
  live apply of `examples/small` (defaults). `scripts/preflight.sh` now also
  checks `container.clusterRoles.create`, `container.clusterRoleBindings.create`,
  `container.roles.create`, and `container.roleBindings.create`, gated on a new
  `CHECK_KEDA_RBAC` toggle (default true, following `CHECK_CLOUD_DNS`'s pattern)
  so it does not reject `install_keda = false` deployments. The README also
  notes that `storage.buckets.setIamPolicy` on the n8n bucket is always
  needed (`roles/editor` usually covers it on a bucket the module creates,
  but not on an existing bucket), that Kubernetes RBAC can replace
  `roles/container.admin` on an existing cluster, and that the preflight
  script checks only a core set of permissions and does not read the
  `create_*` switches, so it can pass while `apply` still fails, or report
  missing permissions on customer-managed paths that `apply` does not need.
  The README no longer lists `certificatemanager.googleapis.com` for
  `tls_mode = "google_managed"`: the module uses a GKE `ManagedCertificate`,
  not Certificate Manager. The API lists now also name the conditional
  `dns` API (`cloud_dns_zone_name` set with `create_ingress = true`) and `orgpolicy` API
  (`manage_sa_key_org_policy = true`) where the example exposes them.
- `scripts/preflight.sh` reported the `iam.disableServiceAccountKeyCreation`
  org policy as unreadable whenever `orgpolicy.googleapis.com` was enabled,
  because `gcloud` prints the effective enforce value as `True`/`False` and
  the script only matched `TRUE`/`FALSE`. A non-enforced policy now reports
  `[ok]`, and an enforced one reports `[BLOCK]` instead of a warning. An
  enforced policy now always sets the warning flag, even when the identity
  holds `orgpolicy.policy.set`, so an otherwise passing run reports
  `PASS with warnings`. With the default `manage_sa_key_org_policy = false`
  and a module-created HMAC key, `apply` fails until the policy is relaxed.

### Security

- The new `keda_chart_version` default, `2.21.0` (see Changed above), is the
  first KEDA release with the fix for the critical CVE-2026-77524
  ([GHSA-637c-6jxx-4rwm](https://github.com/advisories/GHSA-637c-6jxx-4rwm)):
  a namespace admin could escalate to cluster admin through a
  `TriggerAuthentication`. Every earlier KEDA release, including the old
  `2.20.1` default, is affected, whether or not the module's own
  `TriggerAuthentication` uses the affected authentication modes. Callers who
  pin an older `keda_chart_version`, or who manage KEDA themselves with
  `install_keda = false`, must move to `2.21.0` or later to get the fix.

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
