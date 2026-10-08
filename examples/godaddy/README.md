# Example: GoDaddy DNS + Google-managed TLS

Deploys n8n on GKE and manages the DNS record at **GoDaddy** instead of Google
Cloud DNS. TLS is a **Google-managed certificate**: once the GoDaddy A-record
resolves `n8n_fqdn` to the load balancer's static IP, the certificate
provisions automatically (this takes a few minutes on first apply).

Use this example when your domain is registered with GoDaddy and you want to
keep DNS there while running n8n on Google Cloud.

## How it works

1. The module reserves a global static IP for the L7 load balancer and requests
   a Google-managed certificate for `n8n_fqdn` (`tls_mode = "google_managed"`,
   `cloud_dns_zone_name = ""` so the module does not touch Cloud DNS).
2. `dns.tf` creates a GoDaddy A-record for `n8n_fqdn` pointing at that static
   IP via the [`veksh/godaddy-dns`](https://registry.terraform.io/providers/veksh/godaddy-dns/latest)
   provider.
3. Once the record resolves, the managed certificate finishes provisioning and
   n8n is reachable over HTTPS.

`dns.tf` hardcodes a single `godaddy-dns_record` for `n8n_fqdn`; there is no
`n8n_additional_domains`-style passthrough here the way `examples/small` has.
Wiring one through would make the module add extra hostnames to the
Google-managed certificate and Ingress routes, but without a matching GoDaddy
DNS record for each one they would never resolve, so the certificate could
never validate them. Add an alias by adding another `godaddy-dns_record`
resource for it in this file.

## Prerequisites

- A domain registered with GoDaddy, and a [GoDaddy API key/secret](https://developer.godaddy.com/keys).
- Application Default Credentials for GCP: `gcloud auth application-default login`.
- An n8n Enterprise license key (multi-main requires Enterprise).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

export GODADDY_API_KEY=...      # or set godaddy_api_key in tfvars
export GODADDY_API_SECRET=...   # or set godaddy_api_secret in tfvars

terraform init
terraform apply
```

`n8n_fqdn` must be a host within `godaddy_domain` (for example `n8n.example.com`
in the GoDaddy zone `example.com`).

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
| <a name="requirement_godaddy-dns"></a> [godaddy-dns](#requirement\_godaddy-dns) | ~> 0.3 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.1 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 6.1 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_godaddy-dns"></a> [godaddy-dns](#provider\_godaddy-dns) | ~> 0.3 |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.1 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [godaddy-dns_record.n8n](https://registry.terraform.io/providers/veksh/godaddy-dns/latest/docs/resources/record) | resource |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module creates. | `string` | `"godaddy"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west3). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the GCS bucket even if it still holds objects. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_godaddy_api_key"></a> [godaddy\_api\_key](#input\_godaddy\_api\_key) | GoDaddy API key. Can also be supplied via the GODADDY\_API\_KEY environment variable. Create one at https://developer.godaddy.com/keys. | `string` | `""` | no |
| <a name="input_godaddy_api_secret"></a> [godaddy\_api\_secret](#input\_godaddy\_api\_secret) | GoDaddy API secret corresponding to godaddy\_api\_key. Can also be supplied via the GODADDY\_API\_SECRET environment variable. | `string` | `""` | no |
| <a name="input_godaddy_domain"></a> [godaddy\_domain](#input\_godaddy\_domain) | The GoDaddy zone (registered domain) that owns n8n\_fqdn, e.g. example.com. | `string` | n/a | yes |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation on the project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. Must be within godaddy\_domain. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. | `string` | `""` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n\_main\_hpa\_enabled description for the required license edition and maintenance implications. | `number` | `null` | no |
| <a name="input_postgres_backup_retained_backups"></a> [postgres\_backup\_retained\_backups](#input\_postgres\_backup\_retained\_backups) | Number of automated backups Cloud SQL retains. Null (the default) preserves the provider's own default retention. Passed straight through to the module's postgres\_backup\_retained\_backups. | `number` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_transaction_log_retention_days"></a> [postgres\_transaction\_log\_retention\_days](#input\_postgres\_transaction\_log\_retention\_days) | Days of transaction logs Cloud SQL retains for point-in-time recovery. Null (the default) preserves the provider's own default. Passed straight through to the module's postgres\_transaction\_log\_retention\_days. | `number` | `null` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |

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
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | LB static IP that the GoDaddy A-record points at. |
<!-- END_TF_DOCS -->
