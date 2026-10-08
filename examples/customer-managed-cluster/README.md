# Example: n8n on an existing GKE cluster

Deploys n8n onto an existing regional GKE cluster instead of letting the module
create one (`create_gke = false`). Every other layer (VPC, Cloud SQL,
Memorystore, GCS, ingress, DNS) is module-managed, same as
[`../small`](../small). See
[`../../docs/customer-managed-infrastructure.md`](../../docs/customer-managed-infrastructure.md)
for the full ownership matrix and every layer's contract.

## Prerequisites

- An existing **regional** GKE cluster in `gcp_region` that:
  - Is reachable by the `google`/`kubernetes`/`helm`/`kubectl` providers
    configured in `providers.tf` (Application Default Credentials with access
    to the cluster).
  - Uses **VPC-native (alias IP) networking**.
  - Has **Workload Identity** enabled (same-project pool, or set
    `existing_gke_workload_identity_pool` for a cross-project binding, not
    exposed by this example - add it to `main.tf` if you need it).
  - Runs GKE's native ingress, metrics server, cluster autoscaler, and PD CSI
    controllers (the module never installs these).
  - Has spare node capacity for the n8n workload; see the module's capacity
    guardrail checks for a plan-time estimate against a module-managed node
    pool (skipped here, since node shape is outside this module's control).
  - Grants the credentials used by this `terraform apply` permission to
    create namespaced Kubernetes resources (namespace, Secrets, Deployments,
    Services, HPAs, ScaledObjects).
- APIs: `container`, `sqladmin`, `redis`, `servicenetworking`, `compute`, `iam`.
- Org policy `iam.disableServiceAccountKeyCreation` OFF (GCS HMAC). Either
  disable it out-of-band, or set `manage_sa_key_org_policy = true`.
- `gcloud auth application-default login`.

`existing_gke_prerequisites_attestation` has no default: set it to `true` in
`terraform.tfvars` only after confirming the above against your own cluster.
The module cannot safely audit these properties; it trusts the attestation.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

## Production considerations

This example's defaults favor easy teardown over production hardening. Before running this against a real workload, review:

- `postgres_deletion_protection` (default `true`) blocks `terraform destroy` of the Cloud SQL instance.
- `postgres_backup_retained_backups` / `postgres_transaction_log_retention_days` (both default `null`, meaning "Cloud SQL's own default") let you raise backup/PITR retention beyond the provider default.
- `gcs_force_destroy` (default `false`) blocks `terraform destroy` from deleting a non-empty GCS bucket.

See [`docs/destroy-cleanup.md`](../../docs/destroy-cleanup.md) for the full teardown sequence, including why a retained snapshot or bucket becomes unrecoverable once a module-managed Cloud KMS key finishes its deletion window.

Status: preliminary / not scale-validated.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.1 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 6.1 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.1 |

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
| <a name="input_existing_gke_cluster_name"></a> [existing\_gke\_cluster\_name](#input\_existing\_gke\_cluster\_name) | Name of the existing regional GKE cluster (in gcp\_region) to deploy n8n onto. See README.md for the required cluster properties. | `string` | n/a | yes |
| <a name="input_existing_gke_prerequisites_attestation"></a> [existing\_gke\_prerequisites\_attestation](#input\_existing\_gke\_prerequisites\_attestation) | Explicit confirmation that existing\_gke\_cluster\_name is reachable by the providers configured in providers.tf, uses VPC-native networking, has Workload Identity enabled, runs GKE's native ingress/metrics/autoscaling/PD CSI controllers, has capacity for the requested n8n workload, and grants this deployment permission to create namespaced resources. No default: set it to true only after confirming these against your own cluster (see README.md). | `bool` | n/a | yes |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module still creates. | `string` | `"dev"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region of the existing regional GKE cluster (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the (non-empty) GCS bucket. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Additional hostnames to give the full main/webhook route set alongside n8n\_fqdn. Passed straight through to the module's n8n\_additional\_domains. Default empty (no aliases). | `list(string)` | `[]` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | `""` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n\_main\_hpa\_enabled description for the required license edition and maintenance implications. | `number` | `null` | no |
| <a name="input_postgres_backup_retained_backups"></a> [postgres\_backup\_retained\_backups](#input\_postgres\_backup\_retained\_backups) | Number of automated backups Cloud SQL retains. Null (the default) preserves the provider's own default retention. Passed straight through to the module's postgres\_backup\_retained\_backups. | `number` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_transaction_log_retention_days"></a> [postgres\_transaction\_log\_retention\_days](#input\_postgres\_transaction\_log\_retention\_days) | Days of transaction logs Cloud SQL retains for point-in-time recovery. Null (the default) preserves the provider's own default. Passed straight through to the module's postgres\_transaction\_log\_retention\_days. | `number` | `null` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. Must own (or share Workload Identity with) existing\_gke\_cluster\_name. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | Effective GCS bucket for n8n binary data. |
| <a name="output_gke_cluster_name"></a> [gke\_cluster\_name](#output\_gke\_cluster\_name) | Effective GKE cluster name; should equal existing\_gke\_cluster\_name. |
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
