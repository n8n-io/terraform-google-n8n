# Example: n8n on GKE (medium)

Same substrate as [`../small`](../small) (the module creates the VPC, GKE cluster,
Cloud SQL, Memorystore, GCS, and, when `dns_managed_zone` is set, the Cloud DNS
A-record; TLS is a Google-managed certificate), sized for **steady production /
moderate load**.

Sizing vs the module defaults (small):

| Dimension | small (default) | medium |
|---|---|---|
| Cloud SQL tier | `db-g1-small` | `db-custom-4-15360` (4 vCPU / 15 GB) |
| Cloud SQL disk | 50 GB | 100 GB |
| Memorystore | BASIC, 1 GB | STANDARD_HA, 4 GB |
| Node type | `e2-standard-4` | `e2-standard-8` |
| Nodes / zone | 1 -> 2 | 2 -> 5 |
| Worker concurrency | 10 | 15 |
| KEDA workers | 1 -> 10 | 2 -> 30 |
| Webhook HPA | 2 -> 50 | 3 -> 40 |
| Execution concurrency | 100 | 200 |

> **Not scale-validated.** These bounds are a reasoned starting point,
> not measured ceilings. Tune them against a load test before relying on them.

> **Note:** `tls_mode = "google_managed"` is validated end to end (cert issued,
> HTTPS reachable). [`../cloudflare`](../cloudflare) is an alternative; the sizing
> variables here apply there too.

## Prerequisites

- APIs: `container`, `sqladmin`, `redis`, `servicenetworking`, `compute`, `iam`.
- Org policy `iam.disableServiceAccountKeyCreation` OFF (GCS HMAC).
  Either disable it out-of-band, or set `manage_sa_key_org_policy = true` to have
  Terraform do it (needs `roles/orgpolicy.policyAdmin`).
- `gcloud auth application-default login`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

If `dns_managed_zone` is empty, create the A-record yourself against the
`static_ip` output. Status: preliminary / not scale-validated.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.0 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 6.0 |
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
| <a name="input_cloudsql_availability_type"></a> [cloudsql\_availability\_type](#input\_cloudsql\_availability\_type) | REGIONAL (HA failover) or ZONAL. | `string` | `"REGIONAL"` | no |
| <a name="input_cloudsql_deletion_protection"></a> [cloudsql\_deletion\_protection](#input\_cloudsql\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_cloudsql_disk_size"></a> [cloudsql\_disk\_size](#input\_cloudsql\_disk\_size) | Cloud SQL data disk size in GB. | `number` | `100` | no |
| <a name="input_cloudsql_tier"></a> [cloudsql\_tier](#input\_cloudsql\_tier) | Cloud SQL machine tier (ENTERPRISE edition). | `string` | `"db-custom-4-15360"` | no |
| <a name="input_cluster_deletion_protection"></a> [cluster\_deletion\_protection](#input\_cluster\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name prefix for the GKE cluster and derived resources. | `string` | `"n8n-medium"` | no |
| <a name="input_dns_managed_zone"></a> [dns\_managed\_zone](#input\_dns\_managed\_zone) | Google Cloud DNS managed-zone name for n8n\_domain. Empty means you manage the A-record yourself against the static\_ip output. | `string` | `""` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the (non-empty) GCS bucket. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_memorystore_memory_gb"></a> [memorystore\_memory\_gb](#input\_memorystore\_memory\_gb) | Memorystore capacity in GB. | `number` | `4` | no |
| <a name="input_memorystore_tier"></a> [memorystore\_tier](#input\_memorystore\_tier) | Memorystore tier: BASIC or STANDARD\_HA. | `string` | `"STANDARD_HA"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Hostname n8n is served on. | `string` | n/a | yes |
| <a name="input_n8n_execution_concurrency_limit"></a> [n8n\_execution\_concurrency\_limit](#input\_n8n\_execution\_concurrency\_limit) | n8n production execution concurrency limit. | `number` | `200` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | `""` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Webhook-processor HPA ceiling. | `number` | `40` | no |
| <a name="input_n8n_webhook_hpa_min_replicas"></a> [n8n\_webhook\_hpa\_min\_replicas](#input\_n8n\_webhook\_hpa\_min\_replicas) | Webhook-processor HPA floor. | `number` | `3` | no |
| <a name="input_n8n_worker_concurrency"></a> [n8n\_worker\_concurrency](#input\_n8n\_worker\_concurrency) | Concurrent executions per worker pod. | `number` | `15` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | KEDA worker ceiling (pair with node\_max\_per\_zone). | `number` | `30` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | KEDA worker floor. | `number` | `2` | no |
| <a name="input_node_machine_type"></a> [node\_machine\_type](#input\_node\_machine\_type) | GKE node machine type. | `string` | `"e2-standard-8"` | no |
| <a name="input_node_max_per_zone"></a> [node\_max\_per\_zone](#input\_node\_max\_per\_zone) | Autoscaling max nodes per zone. | `number` | `5` | no |
| <a name="input_node_min_per_zone"></a> [node\_min\_per\_zone](#input\_node\_min\_per\_zone) | Autoscaling min nodes per zone (regional cluster ~3 zones). | `number` | `2` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | n/a |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | n/a |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | n/a |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | LB static IP. Point n8n\_domain at this if you are not letting the module manage Cloud DNS. |
<!-- END_TF_DOCS -->
