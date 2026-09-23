# Example: n8n on GKE (large)

Same substrate as [`../small`](../small) (the module creates the VPC, GKE cluster,
Cloud SQL, Memorystore, GCS, and, when `cloud_dns_zone_name` is set, the Cloud DNS
A-record; TLS is a Google-managed certificate), sized for **high throughput**.

Sizing vs the module defaults (small):

| Dimension | small (default) | large |
|---|---|---|
| Cloud SQL tier | `db-g1-small` | `db-custom-8-30720` (8 vCPU / 30 GB) |
| Cloud SQL disk | 50 GB | 250 GB |
| Memorystore | BASIC, 1 GB | STANDARD_HA, 8 GB |
| Node type | `e2-standard-4` | `e2-standard-16` |
| Nodes / zone | 1 -> 2 | 3 -> 10 |
| Worker concurrency | 10 | 20 |
| KEDA workers | 1 -> 10 | 3 -> 80 |
| Main HPA | 2 -> 20 | 3 -> 20 |
| Webhook HPA | 2 -> 50 | 5 -> 80 |
| Execution concurrency | 100 | 400 |

The ceilings set the webhook max to 80 and the worker max to 80. Keep
`gke_node_max_per_zone` high enough to schedule the KEDA worker ceiling.

> **Not scale-validated on GKE.** These bounds are a reasoned starting
> point, not measured ceilings. Tune them against a load test before relying on
> them, and watch the DB write ceiling / connection pooling first (the binding
> constraints, typically reached well before autoscaler bounds).

### Things to watch before you raise these ceilings further

- **Connection-pool budget is lazy and per-pod, not pre-reserved.**
  `db_postgresdb_pool_size` (module default 10, exposed as a passthrough
  above) caps TypeORM connections *per n8n pod*, acquired on demand rather
  than held open from startup. At this tier's ceilings (3 mains + up to 80
  workers + up to 80 webhook processors), the theoretical worst case is
  `db_postgresdb_pool_size * (running main + worker + webhook pod count)`
  concurrent Cloud SQL connections, which can exceed `postgres_machine_type`'s
  `max_connections` well before every autoscaler ceiling is reached. Size
  `db_postgresdb_pool_size` against the actual number of pods you expect to
  run concurrently, not against this tier's autoscaler maximum, and watch
  Cloud SQL's connection count under load.
- **Cluster DNS query volume grows with pod count.** GKE's default cluster
  DNS (`kube-dns`) resolves Cloud SQL/Memorystore hostnames and n8n's
  internal Service names for every main/worker/webhook pod; a high worker
  ceiling under load can raise DNS query volume and, in turn, latency for
  slow lookups. The module's `n8n_dns_config` input lets you point n8n pods
  at a different resolver, search list, or `ndots` value if cluster DNS
  becomes a bottleneck; this example does not set it.
- **The V8 heap ceiling applies to every n8n container, not just the busiest
  one.** `n8n_node_max_old_space_size_mb` (module default: unset, so Node's
  own default applies) sets one `NODE_OPTIONS=--max-old-space-size` value
  across main, worker, and webhook-processor containers. If you raise it,
  leave non-heap headroom (Node's own overhead, buffers, native modules)
  beneath the *smallest* configured container memory limit across all three
  roles, not just the worker's.
- **Boot-disk size affects image and ephemeral-storage pressure, not just
  cluster cost.** `gke_node_disk_size_gb` (module default 100, exposed as a
  passthrough above) is shared per node across the container runtime, pulled
  images (n8n and task-runner images can be sizable), and every pod's
  ephemeral storage on that node. Higher pod density at this tier's node
  ceilings raises the odds of disk pressure evictions on an undersized boot
  disk; watch node disk usage under sustained load, particularly if you also
  raise `gke_node_max_per_zone` well beyond this tier's default.
- **Execution retention drives Cloud SQL storage growth at higher
  throughput.** `n8n_pruning_max_age` (default 336 hours / 14 days) and
  `n8n_pruning_max_count` (default 10000) bound how much execution history
  accumulates in Cloud SQL; at this tier's execution-concurrency ceiling
  (`n8n_execution_concurrency_limit = 400`), the default retention window can
  accumulate substantially more execution data than at the module's small
  defaults. Pair a lower retention window, or `n8n_execution_data_storage_mode
  = "s3"` for execution-data offload, with `postgres_disk_size` growth
  expectations.
- **Opt-in Memorystore RDB persistence is last-snapshot recovery, not a
  throughput feature.** This example leaves `redis_persistence_enabled` at
  its default `false`. Enabling it trades memory and write-latency overhead
  (Memorystore periodically serializes the full keyspace) for automatic
  recovery from the last successful snapshot after an instance failure; it
  is not point-in-time recovery and can replay or lose in-flight queue state
  since the last snapshot. Weigh that overhead against this tier's Redis
  throughput requirements before enabling it, and keep independent Redis
  export/import backups if you need durable, inspectable snapshots.

> **Note:** `tls_mode = "google_managed"` is validated end to end (cert issued,
> HTTPS reachable). [`../cloudflare`](../cloudflare) is an alternative; the sizing
> variables here apply there too.

## Prerequisites

- APIs: `container`, `sqladmin`, `redis`, `servicenetworking`, `compute`, `iam`.
- Org policy `iam.disableServiceAccountKeyCreation` OFF (GCS HMAC).
  Either disable it out-of-band, or set `manage_sa_key_org_policy = true` to have
  Terraform do it (needs `roles/orgpolicy.policyAdmin`).
- `gcloud auth application-default login`.
- Enough regional quota for the larger machine types and node count.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

If `cloud_dns_zone_name` is empty, create the A-record yourself against the
`static_ip` output. Status: preliminary / not scale-validated.

## Production considerations

This example's defaults favor easy teardown over production hardening. Before running this against a real workload, review:

- `postgres_deletion_protection` (default `true`) blocks `terraform destroy` of the Cloud SQL instance.
- `postgres_backup_retained_backups` / `postgres_transaction_log_retention_days` (both default `null`, meaning "Cloud SQL's own default") let you raise backup/PITR retention beyond the provider default.
- `gcs_force_destroy` (default `false`) blocks `terraform destroy` from deleting a non-empty GCS bucket.

See [`docs/destroy-cleanup.md`](../../docs/destroy-cleanup.md) for the full teardown sequence, including why a retained snapshot or bucket becomes unrecoverable once a module-managed Cloud KMS key finishes its deletion window.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.0 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloud_dns_zone_name"></a> [cloud\_dns\_zone\_name](#input\_cloud\_dns\_zone\_name) | Google Cloud DNS managed-zone name for n8n\_fqdn. Empty means you manage the A-record yourself against the static\_ip output. | `string` | `""` | no |
| <a name="input_db_postgresdb_pool_size"></a> [db\_postgresdb\_pool\_size](#input\_db\_postgresdb\_pool\_size) | Maximum TypeORM connection pool slots per n8n pod, passed straight through to the module. Defaults to the module's own default of 10, which already covers this tier's rule-of-thumb floor of n8n\_worker\_concurrency / 4 (20 / 4 = 5); raise it only after a load test shows pool exhaustion. | `number` | `10` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module creates. | `string` | `"large"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the (non-empty) GCS bucket. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_gke_node_disk_size_gb"></a> [gke\_node\_disk\_size\_gb](#input\_gke\_node\_disk\_size\_gb) | Node boot disk size in GB, passed straight through to the module. Defaults to the module's own default of 100. | `number` | `100` | no |
| <a name="input_gke_node_disk_type"></a> [gke\_node\_disk\_type](#input\_gke\_node\_disk\_type) | Node boot disk type (pd-standard, pd-balanced, pd-ssd), passed straight through to the module. Defaults to the module's own default of pd-balanced. | `string` | `"pd-balanced"` | no |
| <a name="input_gke_node_max_per_zone"></a> [gke\_node\_max\_per\_zone](#input\_gke\_node\_max\_per\_zone) | Autoscaling max nodes per zone. Must be high enough to schedule the KEDA worker ceiling below. | `number` | `10` | no |
| <a name="input_gke_node_min_per_zone"></a> [gke\_node\_min\_per\_zone](#input\_gke\_node\_min\_per\_zone) | Autoscaling min nodes per zone (regional cluster ~3 zones). | `number` | `3` | no |
| <a name="input_gke_node_type"></a> [gke\_node\_type](#input\_gke\_node\_type) | GKE node machine type. | `string` | `"e2-standard-16"` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Additional hostnames to give the full main/webhook route set alongside n8n\_fqdn. Passed straight through to the module's n8n\_additional\_domains. Default empty (no aliases). | `list(string)` | `[]` | no |
| <a name="input_n8n_execution_concurrency_limit"></a> [n8n\_execution\_concurrency\_limit](#input\_n8n\_execution\_concurrency\_limit) | n8n production execution concurrency limit. | `number` | `400` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. | `string` | n/a | yes |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n image tag to deploy, passed straight through to the module's n8n\_image\_tag. Null (the default) keeps the chart's own default tag: its appVersion (2.40.5 at chart 1.13.0), which only moves when the module's n8n\_chart\_version does. Pin a concrete version (for example "2.39.7") to upgrade n8n independently of the chart. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | `""` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Main-pod HPA floor. | `number` | `3` | no |
| <a name="input_n8n_redis_timeout_threshold_ms"></a> [n8n\_redis\_timeout\_threshold\_ms](#input\_n8n\_redis\_timeout\_threshold\_ms) | Milliseconds n8n waits for a Redis response before treating the connection as failed. Must be at least 30000 (30s) when redis\_tier = STANDARD\_HA. | `number` | `30000` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Webhook-processor HPA ceiling. | `number` | `80` | no |
| <a name="input_n8n_webhook_hpa_min_replicas"></a> [n8n\_webhook\_hpa\_min\_replicas](#input\_n8n\_webhook\_hpa\_min\_replicas) | Webhook-processor HPA floor. | `number` | `5` | no |
| <a name="input_n8n_worker_concurrency"></a> [n8n\_worker\_concurrency](#input\_n8n\_worker\_concurrency) | Concurrent executions per worker pod. | `number` | `20` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | KEDA worker ceiling (pair with gke\_node\_max\_per\_zone). | `number` | `80` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | KEDA worker floor. | `number` | `3` | no |
| <a name="input_postgres_availability_type"></a> [postgres\_availability\_type](#input\_postgres\_availability\_type) | REGIONAL (HA failover) or ZONAL. | `string` | `"REGIONAL"` | no |
| <a name="input_postgres_backup_retained_backups"></a> [postgres\_backup\_retained\_backups](#input\_postgres\_backup\_retained\_backups) | Number of automated backups Cloud SQL retains. Null (the default) preserves the provider's own default retention. Passed straight through to the module's postgres\_backup\_retained\_backups. | `number` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_disk_size"></a> [postgres\_disk\_size](#input\_postgres\_disk\_size) | Cloud SQL data disk size in GB. | `number` | `250` | no |
| <a name="input_postgres_machine_type"></a> [postgres\_machine\_type](#input\_postgres\_machine\_type) | Cloud SQL machine tier (ENTERPRISE edition). | `string` | `"db-custom-8-30720"` | no |
| <a name="input_postgres_transaction_log_retention_days"></a> [postgres\_transaction\_log\_retention\_days](#input\_postgres\_transaction\_log\_retention\_days) | Days of transaction logs Cloud SQL retains for point-in-time recovery. Null (the default) preserves the provider's own default. Passed straight through to the module's postgres\_transaction\_log\_retention\_days. | `number` | `null` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |
| <a name="input_redis_memory_size_gb"></a> [redis\_memory\_size\_gb](#input\_redis\_memory\_size\_gb) | Memorystore capacity in GB. | `number` | `8` | no |
| <a name="input_redis_tier"></a> [redis\_tier](#input\_redis\_tier) | Memorystore tier: BASIC or STANDARD\_HA. | `string` | `"STANDARD_HA"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | Effective GCS bucket for n8n binary data. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | n/a |
| <a name="output_n8n_ingress_hosts"></a> [n8n\_ingress\_hosts](#output\_n8n\_ingress\_hosts) | Effective hostnames n8n serves (n8n\_fqdn plus n8n\_additional\_domains). |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | n/a |
| <a name="output_n8n_main_service_name"></a> [n8n\_main\_service\_name](#output\_n8n\_main\_service\_name) | Kubernetes Service serving n8n main UI/API traffic. |
| <a name="output_n8n_service_port"></a> [n8n\_service\_port](#output\_n8n\_service\_port) | Port the main and webhook Services listen on. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | n/a |
| <a name="output_n8n_webhook_route_prefixes"></a> [n8n\_webhook\_route\_prefixes](#output\_n8n\_webhook\_route\_prefixes) | Path prefixes that must route to the webhook Service. |
| <a name="output_n8n_webhook_service_name"></a> [n8n\_webhook\_service\_name](#output\_n8n\_webhook\_service\_name) | Kubernetes Service serving n8n webhook traffic. |
| <a name="output_redis_exporter_service_name"></a> [redis\_exporter\_service\_name](#output\_redis\_exporter\_service\_name) | Redis exporter metrics Service name, or null when redis\_exporter\_enabled = false. |
| <a name="output_redis_host"></a> [redis\_host](#output\_redis\_host) | Effective Redis host (module-managed Memorystore or external). |
| <a name="output_redis_tls_enabled"></a> [redis\_tls\_enabled](#output\_redis\_tls\_enabled) | Whether the effective Redis connection uses TLS. |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | LB static IP. Point n8n\_fqdn at this if you are not letting the module manage Cloud DNS. |
<!-- END_TF_DOCS -->
