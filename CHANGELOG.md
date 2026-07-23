# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md, Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Changed

- **Breaking:** `cluster_name` is replaced by `friendly_name_prefix` as the
  naming driver for every Google Cloud resource the module creates. The
  naming scheme is `<friendly_name_prefix>-n8n<-suffix>` (e.g. the GKE
  cluster is `<friendly_name_prefix>-n8n`, Cloud SQL is
  `<friendly_name_prefix>-n8n-pg`). `friendly_name_prefix` is required, must
  not contain `n8n`, and is capped at 30 characters.
- **Breaking:** output `cluster_name` is renamed to `gke_cluster_name`,
  `cluster_endpoint` to `gke_cluster_endpoint`, and `cluster_ca_certificate`
  to `gke_cluster_ca_certificate`.
- Added `common_labels` (`map(string)`, default `{}`), merged into every
  taggable resource's label set alongside the module's built-in labels.
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
