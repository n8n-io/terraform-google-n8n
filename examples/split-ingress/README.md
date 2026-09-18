# Example: Google-native split ingress (public webhooks / private editor)

`create_ingress = false`: the module creates the VPC, GKE cluster, Cloud SQL,
Memorystore, and GCS, but this example owns ingress, DNS, and TLS entirely
(see the module's `create_ingress` and `n8n_ingress_hosts`/route-prefix
outputs). Two separate GKE Ingress objects split the surface:

- **Public** (`gce` class, global external IP): webhook families only
  (`/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, `/mcp`). No
  editor/API route, so the editor is never reachable from the public
  hostname.
- **Private** (`gce-internal` class, regional internal IP): editor/API
  catch-all plus the same webhook families, reachable only from inside the
  VPC (or wherever you extend private reachability to: VPN, Interconnect, a
  peered network).

This is not the module's own managed ingress (`examples/small`,
`examples/cloudflare`, `examples/godaddy`); it is a reference for building a
customer-managed ingress from the module's Service/route/port outputs when
the built-in single-ingress path doesn't fit your exposure requirements. Both
`kubernetes_ingress_v1` resources (`ingress.tf`) route through the module's
own `n8n_webhook_route_prefixes`/`n8n_main_route_prefixes` outputs, so a
chart upgrade that changes the webhook family list changes this example's
routing the same way it changes the module's built-in managed ingress.

> **Status:** not scale-validated. This example is plan-tested with mocked
> providers (`terraform test`); it has not been applied against a real GKE
> cluster as part of this change. Follow the DNS/TLS prerequisites below
> before relying on it.

## What this example creates that `examples/small` doesn't

| Resource | Purpose |
| --- | --- |
| `google_compute_global_address.public` | Static IP for the public webhook ingress. |
| `google_compute_address.private` | Static internal IP for the private editor ingress, in the module's own node subnetwork. |
| `google_compute_subnetwork.proxy_only` | Regional proxy-only subnet (`REGIONAL_MANAGED_PROXY`/`ACTIVE`) the internal ALB's managed proxies use to reach backends. Holds no pod/node/service addresses. |
| `google_compute_firewall.allow_proxy_connection` | Allows the proxy-only subnet to reach n8n's Service port. GKE's Ingress controller creates the public health-check firewall rule automatically, but not this one. |
| `kubernetes_service_v1.webhook_public` | ClusterIP Service selecting the chart's webhook-processor pods, for the public Ingress. Separate from the chart's own `n8n-webhook-processor` Service so it can carry its own BackendConfig. |
| `kubernetes_service_v1.main_private`, `kubernetes_service_v1.webhook_private` | ClusterIP Services selecting the chart's main and webhook-processor pods respectively, for the private Ingress. |
| `kubectl_manifest.backendconfig_public`, `kubectl_manifest.backendconfig_private` | Health check (both) plus session affinity (private only, for the editor's WebSocket/push connections). |
| `kubectl_manifest.public_managed_certificate` | Google-managed certificate for the public host. |
| `kubernetes_secret_v1.private_tls` | Caller-supplied TLS Secret for the private host; see "TLS" below. |
| `kubernetes_ingress_v1.public` | Public `gce`-class Ingress on `public_webhook_fqdn`: the five webhook families only, no editor/API route. |
| `kubernetes_ingress_v1.private` | Private `gce-internal`-class Ingress on `n8n_fqdn`: editor/API catch-all plus the same webhook families, using the caller-supplied TLS Secret. |

## Prerequisites

- Everything `examples/small` requires: APIs (`container`, `sqladmin`,
  `redis`, `servicenetworking`, `compute`, `iam`), the
  `iam.disableServiceAccountKeyCreation` org policy off (or
  `manage_sa_key_org_policy = true`), and
  `gcloud auth application-default login`.
- A GCP region that supports GKE's regional internal Application Load
  Balancing (most do).
- `proxy_only_subnet_cidr` must not overlap the module's VPC ranges (default
  subnet `10.0.0.0/20`, pods `10.4.0.0/14`, services `10.8.0.0/20`).

## DNS (caller-managed; this example creates none)

- **Public**: point `public_webhook_fqdn` (an A record, in whatever DNS
  provider/zone you use) at the `public_ip` output. The Google-managed
  certificate (`kubectl_manifest.public_managed_certificate`) provisions once
  that record resolves, the same way `examples/small`'s canonical host does.
- **Private**: point `n8n_fqdn` at the `private_ip` output from wherever
  n8n administrators resolve it: a Cloud DNS private zone, split-horizon DNS,
  or a `/etc/hosts` entry for testing. This example does not create a Cloud
  DNS zone or record for the private host; unlike the public path, "private
  reachability" depends on your network topology (VPN, Interconnect, a peered
  network) as well as DNS, which is out of scope for a Terraform example.

## TLS

- **Public**: a Google-managed certificate, provisioned automatically once
  DNS resolves (see above). No caller action beyond the DNS record.
- **Private**: GKE's internal Application Load Balancer does not support
  Google-managed certificates; it consumes a Kubernetes TLS Secret instead.
  Supply `internal_tls_cert_pem`/`internal_tls_key_pem` covering `n8n_fqdn`
  (e.g. issued by an internal CA). This example never generates or
  self-signs a certificate for you. The private Ingress explicitly disables
  HTTP, so clients must use HTTPS; there is no HTTP-to-HTTPS redirect.
  Serving both protocols on one internal address would require reserving it
  with `purpose = "SHARED_LOADBALANCER_VIP"`. See
  [GKE internal Ingress TLS requirements](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress#https_between_client_and_load_balancer).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

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
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google_compute_address.private](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_address) | resource |
| [google_compute_firewall.allow_proxy_connection](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_global_address.public](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_subnetwork.proxy_only](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [kubectl_manifest.backendconfig_private](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.backendconfig_public](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.public_managed_certificate](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_ingress_v1.private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.public](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_secret_v1.private_tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.main_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.webhook_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.webhook_public](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource this example and the module create. | `string` | `"split"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west1). Must support GKE regional internal Application Load Balancing (most regions do). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the (non-empty) GCS bucket. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_internal_tls_cert_pem"></a> [internal\_tls\_cert\_pem](#input\_internal\_tls\_cert\_pem) | PEM certificate for the private ingress's TLS Secret, covering n8n\_fqdn. GKE's internal Application Load Balancer does not provision Google-managed certificates, so this is a caller-supplied prerequisite (e.g. from an internal CA); the module and this example never generate or self-sign it. | `string` | n/a | yes |
| <a name="input_internal_tls_key_pem"></a> [internal\_tls\_key\_pem](#input\_internal\_tls\_key\_pem) | PEM private key corresponding to internal\_tls\_cert\_pem. | `string` | n/a | yes |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Private hostname n8n's editor/API is served on. Reachable only through the internal ingress (google\_compute\_address.private); not publicly resolvable. Also used as N8N\_EDITOR\_BASE\_URL by the module. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | `""` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n\_main\_hpa\_enabled description for the required license edition and maintenance implications. | `number` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |
| <a name="input_proxy_only_subnet_cidr"></a> [proxy\_only\_subnet\_cidr](#input\_proxy\_only\_subnet\_cidr) | CIDR range for the regional proxy-only subnet the internal Application Load Balancer's managed proxies use to reach backends. Must not overlap the module's VPC (network.tf's subnet\_cidr/pods\_cidr/services\_cidr) or this subnet's own firewall rule's source range. See Google's example range in the internal-ingress guide. | `string` | `"10.129.0.0/23"` | no |
| <a name="input_public_webhook_fqdn"></a> [public\_webhook\_fqdn](#input\_public\_webhook\_fqdn) | Public hostname n8n's webhooks are served on. Reachable through the public ingress (google\_compute\_global\_address.public); passed to the module as n8n\_webhook\_url so WEBHOOK\_URL/N8N\_WEBHOOK\_URL resolve externally while the editor stays private. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | Effective GCS bucket for n8n binary data. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | n/a |
| <a name="output_n8n_editor_url"></a> [n8n\_editor\_url](#output\_n8n\_editor\_url) | Private editor URL, reachable only through the internal ingress. |
| <a name="output_n8n_ingress_hosts"></a> [n8n\_ingress\_hosts](#output\_n8n\_ingress\_hosts) | Effective hostnames n8n serves (n8n\_fqdn plus n8n\_additional\_domains). |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | n/a |
| <a name="output_n8n_main_service_name"></a> [n8n\_main\_service\_name](#output\_n8n\_main\_service\_name) | Kubernetes Service serving n8n main UI/API traffic. |
| <a name="output_n8n_service_port"></a> [n8n\_service\_port](#output\_n8n\_service\_port) | Port the main and webhook Services listen on. |
| <a name="output_n8n_webhook_route_prefixes"></a> [n8n\_webhook\_route\_prefixes](#output\_n8n\_webhook\_route\_prefixes) | Path prefixes that must route to the webhook Service. |
| <a name="output_n8n_webhook_service_name"></a> [n8n\_webhook\_service\_name](#output\_n8n\_webhook\_service\_name) | Kubernetes Service serving n8n webhook traffic. |
| <a name="output_n8n_webhook_url"></a> [n8n\_webhook\_url](#output\_n8n\_webhook\_url) | Public webhook base URL, reachable through the public ingress. |
| <a name="output_private_ip"></a> [private\_ip](#output\_private\_ip) | Regional internal static IP for the private editor+webhook ingress. Point n8n\_fqdn at this from a private DNS zone/resolver reachable by whoever administers n8n (VPN, interconnect, or a Cloud DNS private zone); this example creates no such DNS resource. |
| <a name="output_public_ip"></a> [public\_ip](#output\_public\_ip) | Global external static IP for the public webhook-only ingress. Point public\_webhook\_fqdn (an A record) at this. |
| <a name="output_redis_exporter_service_name"></a> [redis\_exporter\_service\_name](#output\_redis\_exporter\_service\_name) | Redis exporter metrics Service name, or null when redis\_exporter\_enabled = false. |
| <a name="output_redis_host"></a> [redis\_host](#output\_redis\_host) | Effective Redis host (module-managed Memorystore or external). |
| <a name="output_redis_tls_enabled"></a> [redis\_tls\_enabled](#output\_redis\_tls\_enabled) | Whether the effective Redis connection uses TLS. |
<!-- END_TF_DOCS -->
