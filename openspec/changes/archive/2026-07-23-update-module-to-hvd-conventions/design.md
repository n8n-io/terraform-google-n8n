# Design: HVD interface conventions

## Reference

`/Users/jan/code/terraform/src/terraform-google-terraform-enterprise-gke-hvd`
is the convention source (HashiCorp Validated Design for TFE on GKE). The
sibling module `/Users/jan/code/n8n/src/terraform-aws-n8n` is the source for
community-health file alignment.

Where HVD and the AWS sibling disagree, this design says which wins and why.

## Decisions

### D1: naming driver is `friendly_name_prefix`

- New required variable `friendly_name_prefix` (string, no default) replaces
  `cluster_name` as the driver for every Google Cloud resource name.
- Validation, following the HVD pattern adapted to this module:
  - must not contain `n8n` (avoids `myprefix-n8n-n8n-pg` style redundancy),
  - RFC 1035 label charset: `^[a-z]([a-z0-9-]*[a-z0-9])?$`,
  - length cap chosen so the longest derived name stays within Google Cloud
    limits. Current `cluster_name` is capped at 24; recompute against the
    longest derived suffix during implementation and document the reason in
    the validation error message.
- Naming scheme: `<friendly_name_prefix>-n8n<-suffix>`. Concretely:
  - GKE cluster: `<prefix>-n8n` (was `var.cluster_name`)
  - node pool: `<prefix>-n8n-pool`
  - Cloud SQL instance: `<prefix>-n8n-pg`
  - Memorystore instance: `<prefix>-n8n-redis`
  - GCS bucket: `<project_id>-n8n-<prefix>` (keep project-id prefix for
    global uniqueness)
  - secondary ranges, service accounts, addresses, and any other named
    resource follow the same substitution.
- `local.cluster_name` in `locals.tf` is replaced by a `local.name_prefix`
  (or similar) local so resource files change mechanically.

### D2: `common_labels` merged into the standard label set

- New variable `common_labels` (`map(string)`, default `{}`) with the HVD
  label-charset validation (lowercase keys/values, 63-char cap).
- Merged into `local.gcp_labels` so every taggable resource picks it up
  without per-resource edits. Built-in labels win on key collision.

### D3: variable rename mapping

Service-oriented prefixes per HVD. Semantics and defaults are unchanged
unless noted; only names move.

| Current | New | Notes |
| --- | --- | --- |
| `cluster_name` | removed | replaced by `friendly_name_prefix` (D1) |
| `n8n_domain` | `n8n_fqdn` | HVD `tfe_fqdn` |
| `namespace` | `n8n_kube_namespace` | HVD `tfe_kube_namespace` |
| `k8s_service_account_name` | `n8n_kube_svc_account` | HVD `tfe_kube_svc_account` |
| `dns_managed_zone` | `cloud_dns_zone_name` | behavior unchanged: empty means no record |
| `create_database` | `create_postgres_instance` | HVD `create_*` toggle style |
| `db_host` | `n8n_database_host` | external-database input |
| `db_password` | `n8n_database_password` | external-database input |
| `db_name` | `n8n_database_name` | HVD `tfe_database_name` |
| `db_username` | `n8n_database_user` | HVD `tfe_database_user` |
| `cloudsql_database_version` | `postgres_version` | |
| `cloudsql_edition` | `postgres_edition` | |
| `cloudsql_tier` | `postgres_machine_type` | HVD name |
| `cloudsql_availability_type` | `postgres_availability_type` | |
| `cloudsql_disk_size` | `postgres_disk_size` | |
| `cloudsql_deletion_protection` | `postgres_deletion_protection` | |
| `memorystore_tier` | `redis_tier` | |
| `memorystore_memory_gb` | `redis_memory_size_gb` | HVD name |
| `memorystore_redis_version` | `redis_version` | |
| `memorystore_auth_enabled` | `redis_auth_enabled` | |
| `node_machine_type` | `gke_node_type` | HVD name |
| `node_min_per_zone` | `gke_node_min_per_zone` | |
| `node_max_per_zone` | `gke_node_max_per_zone` | |
| `node_disk_size_gb` | `gke_node_disk_size_gb` | |
| `node_disk_type` | `gke_node_disk_type` | |
| `cluster_deletion_protection` | `gke_deletion_protection` | HVD name |
| `enable_private_nodes` | `gke_enable_private_nodes` | |
| `master_ipv4_cidr` | `gke_control_plane_cidr` | HVD name |
| `master_authorized_networks` | `gke_control_plane_authorized_networks` | keep the `list(object)` type; HVD's single-CIDR string is less capable |

Deliberately kept as-is:

- `project_id`, `gcp_region`: HVD has no region variable (it relies on the
  provider); this module passes the region into many resources and the AWS
  sibling exposes `aws_region`, so `gcp_region` stays for sibling symmetry.
- `db_postgresdb_pool_size`, `db_postgresdb_ssl_enabled`: these mirror n8n's
  own `DB_POSTGRESDB_*` environment variable names, which is more useful to
  operators than an HVD-style rename.
- Network inputs (`subnet_cidr`, `pods_cidr`, `services_cidr`,
  `psa_prefix_length`, `psa_cleanup_destroy_duration`): the VPC design
  decision is deferred, so these do not move in this change.
- TLS inputs (`tls_mode`, `tls_cert_pem`, `tls_key_pem`, `tls_secret_name`,
  `https_redirect`), GCS HMAC inputs, `gcs_location`, `gcs_force_destroy`,
  `manage_sa_key_org_policy`, `gke_release_channel`,
  `gke_min_master_version`, and all `n8n_*` application-tuning variables:
  already convention-conformant.

### D4: output rename mapping

| Current | New |
| --- | --- |
| `cloudsql_private_ip` | `postgres_private_ip` |
| `cloudsql_connection_name` | `postgres_connection_name` |
| `db_password` | `n8n_database_password` |
| `memorystore_host` | `redis_host` |
| `cluster_name` | `gke_cluster_name` |
| `cluster_endpoint` | `gke_cluster_endpoint` |
| `cluster_ca_certificate` | `gke_cluster_ca_certificate` |
| `namespace` | `n8n_kube_namespace` |

All other outputs keep their names. `sensitive` flags are unchanged.

### D5: file layout and banner style stay

- The `variables.tf` / `variables_gcp.tf` split stays (documented in
  `AGENTS.md`); variables move between concern sections as needed but the
  two-file layout is not consolidated.
- The repo's existing `# ── Section ──` banner style stays; do not adopt the
  HVD `#---` banner style.

### D6: housekeeping alignment source is `terraform-aws-n8n`

- Copy the pull-request template and `ISSUE_TEMPLATE/bug.yml` /
  `feature.yml` from `terraform-aws-n8n`, adapting provider-specific wording
  (EKS to GKE, AWS to Google Cloud, ALB to GKE Ingress).
- Add `.github/CODEOWNERS` with a `*` rule owned by the maintainers `@jrx`
  and `@buddy-n8n`.
- Add `SUPPORT.md` pointing to GitHub issues and the n8n community forum,
  consistent in tone with `SECURITY.md`.
- Where `CONTRIBUTING.md` / `SECURITY.md` differ from the AWS sibling only in
  provider specifics, leave them; align structure and shared wording where
  they have drifted for no reason.

### D7: troubleshooting doc mirrors the AWS sibling

`docs/troubleshooting.md` follows the section structure of
`terraform-aws-n8n/docs/troubleshooting.md`, replacing AWS mechanics with
their GKE equivalents (GKE Ingress and ManagedCertificate instead of ALB and
ACM, Cloud SQL instead of RDS, Memorystore instead of ElastiCache, Workload
Identity instead of IRSA-style roles).

## Testing strategy

Plan-time `terraform test` with mocked providers, per `AGENTS.md`:

- Assert `friendly_name_prefix` drives resource names (for example
  `google_container_cluster.n8n.name == "<prefix>-n8n"`).
- Assert `common_labels` entries appear in a labeled resource's `labels`.
- Assert validators reject an invalid `friendly_name_prefix` (contains
  `n8n`, bad charset, too long) via `expect_failures`.
- Update every existing assertion that references a renamed variable or
  output; the five example suites catch caller-side wiring.
- Helm values content remains unassertable at plan time (known mock
  limitation in `AGENTS.md`); variable-contract assertions suffice.
