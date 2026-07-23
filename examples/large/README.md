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

The ceilings set the webhook max to 80 and the worker max to 160. Keep
`gke_node_max_per_zone` high enough to schedule the KEDA worker ceiling.

> **Not scale-validated on GKE.** These bounds are a reasoned starting
> point, not measured ceilings. Tune them against a load test before relying on
> them, and watch the DB write ceiling / connection pooling first (the binding
> constraints, typically reached well before autoscaler bounds).

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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

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
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module creates. | `string` | `"large"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the (non-empty) GCS bucket. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_gke_node_max_per_zone"></a> [gke\_node\_max\_per\_zone](#input\_gke\_node\_max\_per\_zone) | Autoscaling max nodes per zone. Must be high enough to schedule the KEDA worker ceiling below. | `number` | `10` | no |
| <a name="input_gke_node_min_per_zone"></a> [gke\_node\_min\_per\_zone](#input\_gke\_node\_min\_per\_zone) | Autoscaling min nodes per zone (regional cluster ~3 zones). | `number` | `3` | no |
| <a name="input_gke_node_type"></a> [gke\_node\_type](#input\_gke\_node\_type) | GKE node machine type. | `string` | `"e2-standard-16"` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_n8n_execution_concurrency_limit"></a> [n8n\_execution\_concurrency\_limit](#input\_n8n\_execution\_concurrency\_limit) | n8n production execution concurrency limit. | `number` | `400` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | `""` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Main-pod HPA floor. | `number` | `3` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Webhook-processor HPA ceiling. | `number` | `80` | no |
| <a name="input_n8n_webhook_hpa_min_replicas"></a> [n8n\_webhook\_hpa\_min\_replicas](#input\_n8n\_webhook\_hpa\_min\_replicas) | Webhook-processor HPA floor. | `number` | `5` | no |
| <a name="input_n8n_worker_concurrency"></a> [n8n\_worker\_concurrency](#input\_n8n\_worker\_concurrency) | Concurrent executions per worker pod. | `number` | `20` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | KEDA worker ceiling (pair with gke\_node\_max\_per\_zone). | `number` | `80` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | KEDA worker floor. | `number` | `3` | no |
| <a name="input_postgres_availability_type"></a> [postgres\_availability\_type](#input\_postgres\_availability\_type) | REGIONAL (HA failover) or ZONAL. | `string` | `"REGIONAL"` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_disk_size"></a> [postgres\_disk\_size](#input\_postgres\_disk\_size) | Cloud SQL data disk size in GB. | `number` | `250` | no |
| <a name="input_postgres_machine_type"></a> [postgres\_machine\_type](#input\_postgres\_machine\_type) | Cloud SQL machine tier (ENTERPRISE edition). | `string` | `"db-custom-8-30720"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |
| <a name="input_redis_memory_size_gb"></a> [redis\_memory\_size\_gb](#input\_redis\_memory\_size\_gb) | Memorystore capacity in GB. | `number` | `8` | no |
| <a name="input_redis_tier"></a> [redis\_tier](#input\_redis\_tier) | Memorystore tier: BASIC or STANDARD\_HA. | `string` | `"STANDARD_HA"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | n/a |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | n/a |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | n/a |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | LB static IP. Point n8n\_fqdn at this if you are not letting the module manage Cloud DNS. |
<!-- END_TF_DOCS -->
