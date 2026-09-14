# Example: n8n with every layer customer-managed

Flips every ownership switch to customer-managed: network, GKE, Cloud SQL,
Redis, GCS bucket, namespace, ingress, HPAs, worker KEDA, and the KEDA
controller install itself. This example creates no VPC, GKE cluster, Cloud
SQL instance, Memorystore instance, GCS bucket, Kubernetes namespace, ingress
resources, HPAs, ScaledObjects, or KEDA release. See
[`../../docs/customer-managed-infrastructure.md`](../../docs/customer-managed-infrastructure.md)
for the full ownership matrix, every layer's contract, and the security
boundary this implies.

Since `create_ingress = false`, this example does not expose n8n externally
by itself; it outputs the stable service and route contract
(`n8n_main_service_name`, `n8n_webhook_service_name`, `n8n_service_port`,
`n8n_main_route_prefixes`, `n8n_webhook_route_prefixes`) so you can build a
compatible ingress on top of it.

## Prerequisites

- An existing VPC network and subnetwork, with secondary ranges for GKE pod
  and service alias IPs (`existing_network_name`, `existing_subnetwork_name`,
  `existing_pods_range_name`, `existing_services_range_name`).
- An existing regional GKE cluster meeting the same properties documented in
  [`../customer-managed-cluster/README.md`](../customer-managed-cluster/README.md#prerequisites).
- An external PostgreSQL database reachable from the existing network
  (`n8n_database_host`), and an existing Kubernetes Secret in the n8n
  namespace holding its password under key `password`.
- An external Redis-compatible service reachable from the existing network
  (`redis_host`), and an existing Kubernetes Secret in the n8n namespace
  holding its password under key `password`.
- An existing GCS bucket (`existing_gcs_bucket_name`) and a pre-existing
  service account with an out-of-band-created HMAC key
  (`gcs_hmac_service_account_email`, `gcs_hmac_access_id`), plus an existing
  Kubernetes Secret holding the HMAC secret under key `accessSecret`.
- An existing Kubernetes namespace (`n8n_kube_namespace`) already present on
  the cluster.
- `gcloud auth application-default login`.

Create every referenced Secret out of band before applying, e.g.:

```bash
kubectl create secret generic external-postgres-password \
  -n existing-n8n-namespace --from-literal=password='...'
kubectl create secret generic external-redis-password \
  -n existing-n8n-namespace --from-literal=password='...'
kubectl create secret generic external-gcs-hmac-secret \
  -n existing-n8n-namespace --from-literal=accessSecret='...'
```

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

Status: preliminary / not scale-validated.

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
| <a name="input_existing_gcs_bucket_name"></a> [existing\_gcs\_bucket\_name](#input\_existing\_gcs\_bucket\_name) | Name of the existing GCS bucket used for n8n binary storage. | `string` | n/a | yes |
| <a name="input_existing_gke_cluster_name"></a> [existing\_gke\_cluster\_name](#input\_existing\_gke\_cluster\_name) | Name of the existing regional GKE cluster (in gcp\_region) to deploy n8n onto. See README.md for the required cluster properties. | `string` | n/a | yes |
| <a name="input_existing_gke_prerequisites_attestation"></a> [existing\_gke\_prerequisites\_attestation](#input\_existing\_gke\_prerequisites\_attestation) | Explicit confirmation that existing\_gke\_cluster\_name is reachable by the providers configured in providers.tf, uses VPC-native networking, has Workload Identity enabled, runs GKE's native ingress/metrics/autoscaling/PD CSI controllers, has capacity for the requested n8n workload, and grants this deployment permission to create namespaced resources. No default: set it to true only after confirming these against your own cluster (see README.md). | `bool` | n/a | yes |
| <a name="input_existing_network_name"></a> [existing\_network\_name](#input\_existing\_network\_name) | Name of the existing VPC network GKE and data services attach to. | `string` | n/a | yes |
| <a name="input_existing_pods_range_name"></a> [existing\_pods\_range\_name](#input\_existing\_pods\_range\_name) | Name of the existing secondary IP range on existing\_subnetwork\_name used for GKE pod alias IPs. | `string` | n/a | yes |
| <a name="input_existing_services_range_name"></a> [existing\_services\_range\_name](#input\_existing\_services\_range\_name) | Name of the existing secondary IP range on existing\_subnetwork\_name used for GKE service alias IPs. | `string` | n/a | yes |
| <a name="input_existing_subnetwork_name"></a> [existing\_subnetwork\_name](#input\_existing\_subnetwork\_name) | Name of the existing subnetwork (in gcp\_region) GKE and data services attach to. | `string` | n/a | yes |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of any resource the module still creates (Workload Identity service account, generated Secrets, n8n Helm release). | `string` | `"dev"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region of the existing network, GKE cluster, and Redis/PostgreSQL/GCS resources (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_hmac_access_id"></a> [gcs\_hmac\_access\_id](#input\_gcs\_hmac\_access\_id) | HMAC access ID (S3 access key) for the pre-existing key named by gcs\_hmac\_service\_account\_email. | `string` | n/a | yes |
| <a name="input_gcs_hmac_secret_name"></a> [gcs\_hmac\_secret\_name](#input\_gcs\_hmac\_secret\_name) | Name of an existing Kubernetes Secret (in n8n\_kube\_namespace) holding the HMAC secret under key "accessSecret". Create this Secret out of band before applying; the module never reads its value. | `string` | n/a | yes |
| <a name="input_gcs_hmac_service_account_email"></a> [gcs\_hmac\_service\_account\_email](#input\_gcs\_hmac\_service\_account\_email) | Email of the pre-existing service account that owns the out-of-band-created HMAC key. The module grants this account objectAdmin on existing\_gcs\_bucket\_name; it does not create the account or the key. | `string` | n/a | yes |
| <a name="input_n8n_database_host"></a> [n8n\_database\_host](#input\_n8n\_database\_host) | External PostgreSQL host reachable from existing\_network\_name. | `string` | n/a | yes |
| <a name="input_n8n_database_password_secret_name"></a> [n8n\_database\_password\_secret\_name](#input\_n8n\_database\_password\_secret\_name) | Name of an existing Kubernetes Secret (in n8n\_kube\_namespace) holding the external database password under key "password". Create this Secret out of band before applying; the module never reads its value. | `string` | n/a | yes |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. Point your own DNS/ingress at whatever address it resolves to; this example does not manage DNS or ingress. | `string` | n/a | yes |
| <a name="input_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#input\_n8n\_kube\_namespace) | Name of the existing Kubernetes namespace to deploy n8n into. Create it out of band before applying. | `string` | `"n8n"` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | n/a | yes |
| <a name="input_n8n_main_fixed_replicas"></a> [n8n\_main\_fixed\_replicas](#input\_n8n\_main\_fixed\_replicas) | Fixed replica count for n8n main pods, passed straight through to the module's own n8n\_main\_fixed\_replicas (this example sets n8n\_main\_hpa\_enabled=false, so the caller's own scaler manages main pods and this input only seeds the replica count). Defaults to the module's own default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n\_main\_hpa\_enabled description for the required license edition and maintenance implications. | `number` | `2` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |
| <a name="input_redis_host"></a> [redis\_host](#input\_redis\_host) | External Redis-compatible host n8n and KEDA connect to. | `string` | n/a | yes |
| <a name="input_redis_password_secret_name"></a> [redis\_password\_secret\_name](#input\_redis\_password\_secret\_name) | Name of an existing Kubernetes Secret (in n8n\_kube\_namespace) holding the external Redis password under key "password". Create this Secret out of band before applying; the module never reads its value. | `string` | n/a | yes |
| <a name="input_redis_tls_enabled"></a> [redis\_tls\_enabled](#input\_redis\_tls\_enabled) | Whether n8n and KEDA connect to redis\_host over TLS. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | Effective GCS bucket; should equal var.existing\_gcs\_bucket\_name. |
| <a name="output_gke_cluster_name"></a> [gke\_cluster\_name](#output\_gke\_cluster\_name) | Effective GKE cluster name; should equal var.existing\_gke\_cluster\_name. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | n/a |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | Effective namespace; should equal var.n8n\_kube\_namespace. |
| <a name="output_n8n_main_route_prefixes"></a> [n8n\_main\_route\_prefixes](#output\_n8n\_main\_route\_prefixes) | n/a |
| <a name="output_n8n_main_service_name"></a> [n8n\_main\_service\_name](#output\_n8n\_main\_service\_name) | n/a |
| <a name="output_n8n_service_port"></a> [n8n\_service\_port](#output\_n8n\_service\_port) | n/a |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | n/a |
| <a name="output_n8n_webhook_route_prefixes"></a> [n8n\_webhook\_route\_prefixes](#output\_n8n\_webhook\_route\_prefixes) | n/a |
| <a name="output_n8n_webhook_service_name"></a> [n8n\_webhook\_service\_name](#output\_n8n\_webhook\_service\_name) | n/a |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | Effective network ID; should resolve to var.existing\_network\_name. |
| <a name="output_postgres_host"></a> [postgres\_host](#output\_postgres\_host) | Effective PostgreSQL host; should equal var.n8n\_database\_host. |
| <a name="output_redis_host"></a> [redis\_host](#output\_redis\_host) | Effective Redis host; should equal var.redis\_host. |
<!-- END_TF_DOCS -->
