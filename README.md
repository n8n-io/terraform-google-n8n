# terraform-google-n8n

Terraform module for deploying [n8n](https://n8n.io) on **Google Kubernetes Engine (GKE)**.

Deploys the production-grade multi-main setup: multiple n8n main instances, dedicated worker pods, webhook processors, external PostgreSQL (Cloud SQL), Redis (Memorystore), and Google Cloud Storage for shared binary data, fronted by a native GKE Ingress (Google Cloud L7 load balancer). An **n8n Enterprise license is required** for multi-main.

This module is a port of the upstream EKS module ([`n8n-io/terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n)); the Kubernetes workload layer (Helm release, KEDA, HPAs) is shared, and only the cloud substrate differs.

> **Pre-release / preliminary**
>
> This module is preliminary and **not scale-validated** (no load test). Expect breaking changes. It encodes a smoke-tested, as-built GKE deployment; open items are tracked in [`ROADMAP.md`](./ROADMAP.md).

---

## ⚠️ Prerequisites (read before `apply`)

### 0. Preflight check (recommended)

Run [`scripts/preflight.sh`](./scripts/preflight.sh) first, it verifies (read-only,
via `testIamPermissions`) that your active identity has the APIs and IAM
permissions this module needs, and reports whether the org policy below is
currently blocking you, so you find out now, not at `apply` time:

```bash
./scripts/preflight.sh YOUR_PROJECT_ID
# for the Cloudflare example (no Cloud DNS): CHECK_CLOUD_DNS=false ./scripts/preflight.sh YOUR_PROJECT_ID
```

Requires `gcloud` (authenticated), `curl`, and `python3`. Exit code is non-zero if a
required API or permission is missing, so it also works as a CI gate.

### 1. Org policy: `iam.disableServiceAccountKeyCreation`

**This is the most common thing that blocks a first apply.** n8n's binary-data driver is S3-compatible, and on GCS that requires an **HMAC key** (static credentials). Creating an HMAC key is blocked by the `iam.disableServiceAccountKeyCreation` organization policy, which many organizations enforce by default. You have two options:

- **Disable it out-of-band (recommended for most).** Have an org/folder administrator turn the constraint off for your project (Console: *IAM & Admin → Organization Policies*, or `gcloud`), then leave `manage_sa_key_org_policy = false`.
- **Let this module do it.** Set `manage_sa_key_org_policy = true`. The module then creates a project-level override that turns the constraint off before creating the HMAC key.

  > **This requires `roles/orgpolicy.policyAdmin`**, which is granted at the **organization or folder** level, a normal project deployer does not have it, and the `apply` will fail on that resource if you lack it. It also **overrides a security guardrail** your platform/security team may have set deliberately. Use this only if you are entitled to change org policy on the target project. It is `false` by default for this reason.

If neither is done, the apply fails when creating `google_storage_hmac_key`.

> **Locked-down orgs (can't relax the policy at all):** bring your own HMAC key.
> Have your platform team create a service account + HMAC key out of band, then
> set `gcs_hmac_service_account_email` and `gcs_hmac_access_id` plus either
> `gcs_hmac_secret_name` (an existing k8s Secret holding the secret under key
> `accessSecret`, keeps the raw secret out of Terraform state, recommended) or
> `gcs_hmac_secret` (the raw value). In this mode the module never calls
> `google_storage_hmac_key`, it just grants your SA access to the bucket and wires
> the credentials into n8n, so a locked-down org never has to relax the org policy
> or fork the module.

### 2. Enable APIs

`container`, `sqladmin`, `redis`, `servicenetworking`, `compute`, `iam` (and `orgpolicy` if using `manage_sa_key_org_policy`, `certificatemanager` for `google_managed` TLS).

### 3. Authentication

`gcloud auth application-default login`, or point `GOOGLE_APPLICATION_CREDENTIALS` at a key file.

### 4. Enterprise license

Multi-main requires an n8n Enterprise license (`n8n_license_key`).

---

## Architecture

Users and inbound webhooks hit a **Google Cloud L7 HTTPS load balancer** provisioned by the native GKE (`gce`) Ingress, using container-native load balancing (NEGs target pods directly). Inside the cluster the n8n Helm chart runs three deployments: main pods (leader election, UI/editor, REST API), webhook-processor pods, and worker pods that scale on Redis queue depth via KEDA. State lives in managed services outside the cluster:

- **Cloud SQL PostgreSQL** (private IP over Private Services Access) for workflow state
- **Memorystore for Redis** for leader election and the worker queue
- **Google Cloud Storage** (S3-compatible, via HMAC key) for binary data

Pods authenticate to GCP via **Workload Identity** (the exception is GCS, which uses the HMAC key). TLS is terminated at the load balancer; the certificate source is selectable (see below).

---

## Usage

The base module is provider-clean and creates its own VPC. The recommended path is to configure it from an example root:

- **[`examples/small`](./examples/small)** , default path: Google Cloud DNS + a Google-managed TLS certificate.
- **[`examples/medium`](./examples/medium)** / **[`examples/large`](./examples/large)** , scaled-up reference architectures (HA database, bigger nodes, higher autoscaling ceilings).
- **[`examples/cloudflare`](./examples/cloudflare)** , Cloudflare DNS + auto-renewing Let's Encrypt via cert-manager (the validated TLS path).
- **[`examples/godaddy`](./examples/godaddy)** , GoDaddy DNS + a Google-managed certificate.

```bash
cd examples/cloudflare
cp terraform.tfvars.example terraform.tfvars   # then edit
gcloud auth application-default login
terraform init && terraform apply
```

Calling the module from your own root works too; your root must then configure
the `google`, `kubernetes`, `helm`, and `kubectl` providers against the cluster
the module creates (copy [`examples/small/providers.tf`](./examples/small/providers.tf)):

```hcl
module "n8n" {
  source  = "n8n-io/n8n/google"
  version = "~> 0.1.0"

  project_id      = "my-project"
  gcp_region      = "europe-west1"
  n8n_domain      = "n8n.example.com"
  n8n_license_key = var.n8n_license_key

  # Optional: let the module manage the DNS A-record in Cloud DNS.
  dns_managed_zone = "example-com"
}
```

---

## TLS (`tls_mode`)

The `gce` Ingress terminates TLS at the load balancer, so the certificate must be presentable to the LB. `tls_mode` selects how:

| `tls_mode` | How | Notes |
|---|---|---|
| `google_managed` (default) | `ManagedCertificate` CR | Auto-renew. Validated end to end. Needs the DNS A-record pointing at the static IP first; the cert then provisions in a few minutes. |
| `secret` | Ingress consumes an existing k8s TLS Secret | How `examples/cloudflare` wires auto-renewing Let's Encrypt (cert-manager + Cloudflare DNS-01). |
| `custom` | Pre-shared cert from your PEM (`tls_cert_pem`/`tls_key_pem`) | e.g. a Cloudflare Origin CA cert (long-lived). |
| `self_signed` | Generated self-signed cert | Smoke tests before DNS is live. |

DNS: the base module can manage a Google Cloud DNS record (`dns_managed_zone`); other providers (Cloudflare, GoDaddy) manage their own record against the `static_ip` output.

---

## Key inputs

| Variable | Description |
|---|---|
| `project_id` | GCP project ID (required). |
| `gcp_region` | Region (e.g. `us-east4`, `europe-west1`). |
| `cluster_name` | Name prefix for the cluster and derived resources (<= 24 chars). |
| `n8n_domain` | Hostname n8n is served on. |
| `n8n_license_key` | n8n Enterprise activation key. |
| `gcs_location` | GCS bucket location; keep near `gcp_region` (`US` / `EU` / a region). |
| `tls_mode` | Certificate source (table above). |
| `manage_sa_key_org_policy` | Opt-in org-policy override for the HMAC key (see Prerequisites). Default `false`. |
| `gcs_hmac_service_account_email` | BYO HMAC mode for locked-down orgs: supply a pre-existing SA (+ `gcs_hmac_access_id` and `gcs_hmac_secret_name`/`gcs_hmac_secret`) and the module skips HMAC-key creation. Default empty. |
| `memorystore_auth_enabled` | Enable Redis AUTH (default off); the module wires the KEDA `TriggerAuthentication` when on. |

Cloud SQL, Memorystore, node-pool sizing, autoscaling bounds, pruning, and OpenTelemetry are all configurable, see `variables.tf` / `variables_gcp.tf`.

## Key outputs

`static_ip`, `n8n_url`, `cluster_name`, `cluster_endpoint`, `kubectl_config_command`, `cloudsql_private_ip`, `memorystore_host`, `gcs_bucket_name`. Sensitive: `db_password`, `n8n_encryption_key`, `gcs_hmac_access_id`, `gcs_hmac_secret` (retrieve with `terraform output -raw <name>`).

## Operations (day-2)

Learnings from the first live deploy:

- **After apply, TLS lags.** The Google L7 LB's HTTPS frontend and cert take a few
  minutes to propagate *after* `apply` returns. `ERR_CONNECTION_CLOSED` right after
  apply is normal, wait ~5-10 min. Check backends and cert:
  ```bash
  kubectl -n n8n get pods
  kubectl -n n8n get certificate n8n-tls          # READY should be True
  kubectl -n n8n describe ingress n8n-ingress      # backends HEALTHY, ssl-cert set
  ```

- **Switching Let's Encrypt staging -> production (examples/cloudflare).** Comment
  out `acme_server` in tfvars (prod is the default) and `apply`, this updates the
  `ClusterIssuer` but does **not** re-issue an already-valid cert. Force one re-issue:
  ```bash
  kubectl -n n8n delete secret n8n-tls    # cert-manager re-requests from prod (~1-2 min)
  ```
  Then the ingress-gce controller mints a new GCP `SslCertificate` and rebinds the
  HTTPS proxy, another **~10 min**. Verify (no `-k`): `curl -sI https://<domain>/healthz`.
  Do this **once**, LE production allows only 5 identical certs per week, so don't
  loop the secret delete.

- **Teardown.** `cluster_deletion_protection` and `cloudsql_deletion_protection`
  default to `true`, so `terraform destroy` refuses until the protection flags are
  flipped on the *live* resources first. Setting the vars to `false` on the destroy
  command alone is not enough (the provider still reads protection from the existing
  resource), you must `apply` the change first:

  ```bash
  # 1. flip protection on the live cluster + SQL instance, and allow bucket destroy
  terraform apply -auto-approve \
    -var cluster_deletion_protection=false \
    -var cloudsql_deletion_protection=false \
    -var gcs_force_destroy=true
  # 2. then destroy (repeat the same -var flags)
  terraform destroy -auto-approve \
    -var cluster_deletion_protection=false \
    -var cloudsql_deletion_protection=false \
    -var gcs_force_destroy=true
  ```

  If a `destroy` already ran and failed partway (leaving only the cluster + SQL +
  network in state), scope the `apply` so it does not try to recreate the
  already-deleted dependents: add `-target=module.n8n.google_container_cluster.n8n
  -target=module.n8n.google_sql_database_instance.n8n` to step 1, then `destroy`.

  The destroy-time `time_sleep` pauses 60s for the LB to release before deleting the
  cluster. The Cloud SQL database + user use `deletion_policy = "ABANDON"` so destroy
  deletes the *instance* (which cascades them) instead of issuing `DROP DATABASE`/
  `DROP USER`, which otherwise fail on live connections and the user-owned schema
  objects.

  Finally, the Private Services Access connection often refuses to delete with
  `Producer services (e.g. CloudSQL, Cloud Memstore, ...) are still using this
  connection`, even after the Cloud SQL and Memorystore instances are gone. This can
  persist for 20+ minutes, and re-running `destroy` (or `gcloud services vpc-peerings
  delete`) does not clear it. The reliable unblock is to delete the peering at the
  **compute** level, then re-run `destroy`:

  ```bash
  gcloud compute networks peerings delete servicenetworking-googleapis-com \
    --network=<cluster_name>-vpc --project=<project_id>
  terraform destroy -auto-approve \
    -var cluster_deletion_protection=false \
    -var cloudsql_deletion_protection=false \
    -var gcs_force_destroy=true   # now clears the PSA connection + address + VPC
  ```

  The pause before the peering delete is configurable via
  `psa_cleanup_destroy_duration` (default `3m`); raise it if teardowns stall. See
  [`docs/destroy-cleanup.md`](./docs/destroy-cleanup.md) for the full guide.

## Stability & versioning

This module is pre-1.0. We use minor versions (0.1, 0.2, ...) as the
breaking-change boundary and patches (0.1.0, 0.1.1, ...) for additive and
bug-fix changes.

| Across | What may change |
| ------ | --------------- |
| `0.MINOR.PATCH` -> `0.MINOR.PATCH+1` | Bug fixes, new optional inputs, new outputs, new resources whose absence would not affect existing callers. No removed or renamed inputs/outputs, no changed defaults that move infra, no changed resource addresses. |
| `0.MINOR` -> `0.MINOR+1` | Anything else, including removed or renamed inputs, default changes that force resource replacement, refactored resource addresses, and bumped provider version floors. Each such change is called out in [`CHANGELOG.md`](./CHANGELOG.md) with an upgrade note. |

Pin `version = "~> 0.1.0"` to auto-receive 0.1.x patches without accidentally
crossing the 0.1 -> 0.2 boundary. Note that the three-component constraint
`~> 0.1.0` resolves to `>= 0.1.0, < 0.2.0`, whereas the two-component `~> 0.1`
would resolve to `>= 0.1, < 1.0` and let you cross minor boundaries
unintentionally. This contract goes away at 1.0.0 in favor of standard SemVer.

### Compatibility

The module ships against specific provider majors and validated versions:

- **Google provider:** `~> 6.0` (hashicorp/google).
- **GKE:** validated on a recent GKE `REGULAR` release channel version.
- **PostgreSQL:** validated on Cloud SQL `POSTGRES_16`.
- Callers can pin the n8n application image via `n8n_image_tag` (e.g. `"1.2.3"`)
  to avoid crossing a major-version boundary on an unplanned pod reschedule.

## Out of scope

The following are intentionally not covered today. Each item is documented here
so issues filed against them can be triaged quickly; several are candidates for
future minor releases (see [`ROADMAP.md`](./ROADMAP.md)).

- **Bring your own VPC.** The module creates its own VPC, subnet, and Private
  Service Access range. Deploying into a pre-existing network is not supported
  yet.
- **Multi-region / cross-region deployments.** One module instance is one
  region, one GKE cluster, one n8n deployment. Cross-region replication of the
  database or GCS binary storage is the caller's problem.
- **Air-gapped / private-image deployments.** The module pulls images from
  public registries (the n8n chart and KEDA). It exposes no image-registry
  override inputs today.
- **Backup/DR automation beyond Cloud SQL backups.** The module enables Cloud
  SQL automated backups and point-in-time recovery. It does not automate restore
  drills, cross-region backup copy, or n8n encryption-key escrow. The
  `n8n_encryption_key` output is emitted at apply time; backing it up is the
  operator's job and the single most important thing not to forget.
- **Bundled observability.** The module installs KEDA for worker autoscaling and
  supports OpenTelemetry trace export, but does not install Prometheus, Grafana,
  Loki, or a collector. Point `n8n_otel_exporter_otlp_endpoint` at your own.

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.12 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | ~> 4.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_compute_global_address.lb](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_global_address.psa](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_network.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_router.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router) | resource |
| [google_compute_router_nat.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat) | resource |
| [google_compute_ssl_certificate.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_ssl_certificate) | resource |
| [google_compute_subnetwork.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_container_cluster.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster) | resource |
| [google_container_node_pool.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool) | resource |
| [google_dns_record_set.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_org_policy_policy.disable_sa_key_creation](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/org_policy_policy) | resource |
| [google_project_iam_member.n8n_cloudsql_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_redis_instance.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/redis_instance) | resource |
| [google_service_account.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.storage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.n8n_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_networking_connection.psa](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_connection) | resource |
| [google_sql_database.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database) | resource |
| [google_sql_database_instance.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance) | resource |
| [google_sql_user.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_user) | resource |
| [google_storage_bucket.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.storage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_hmac_key.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_hmac_key) | resource |
| [helm_release.keda](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.n8n](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.backendconfig](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.frontendconfig](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.managed_certificate](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.redis_trigger_auth](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_ingress_v1.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_secret.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_db](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_s3](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.redis_auth](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_storage_class_v1.pd_balanced](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class_v1) | resource |
| [random_id.n8n_encryption_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_password.db_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.task_runner_token](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.wait_for_lb_cleanup](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.wait_for_psa_cleanup](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [tls_private_key.self_signed](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.self_signed](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_deletion_protection"></a> [cluster\_deletion\_protection](#input\_cluster\_deletion\_protection) | Block terraform destroy of the GKE cluster (google provider default is true). | `bool` | `true` | no |
| <a name="input_common_labels"></a> [common\_labels](#input\_common\_labels) | Common labels merged into every taggable Google Cloud resource the module creates. Built-in module labels win on key collision. | `map(string)` | `{}` | no |
| <a name="input_create_postgres_instance"></a> [create\_postgres\_instance](#input\_create\_postgres\_instance) | When true (the default), the module creates and manages a Cloud SQL PostgreSQL instance. Set to false to use an external database (n8n\_database\_host and n8n\_database\_password must then be supplied). Kept as a static boolean rather than `n8n_database_host == null` because count expressions cannot depend on values computed at apply time. | `bool` | `true` | no |
| <a name="input_db_postgresdb_pool_size"></a> [db\_postgresdb\_pool\_size](#input\_db\_postgresdb\_pool\_size) | Number of TypeORM connection pool slots per n8n pod. Each pod holds this many persistent PostgreSQL connections. Rule of thumb: pool\_size >= worker\_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20). | `number` | `10` | no |
| <a name="input_db_postgresdb_ssl_enabled"></a> [db\_postgresdb\_ssl\_enabled](#input\_db\_postgresdb\_ssl\_enabled) | Whether n8n connects to the database over SSL. For Cloud SQL over Private Services Access the recommended default is false: the instance uses ssl\_mode ALLOW\_UNENCRYPTED\_AND\_ENCRYPTED and traffic stays on the VPC private network. Set to true to require SSL; certificate verification is skipped (DB\_POSTGRESDB\_SSL\_REJECT\_UNAUTHORIZED=false). | `bool` | `false` | no |
| <a name="input_dns_managed_zone"></a> [dns\_managed\_zone](#input\_dns\_managed\_zone) | Google Cloud DNS managed-zone name to create the A record in. Empty string means the module does not manage DNS (you point n8n\_domain at the static IP output yourself, as examples/cloudflare does). | `string` | `""` | no |
| <a name="input_enable_private_nodes"></a> [enable\_private\_nodes](#input\_enable\_private\_nodes) | Give nodes private IPs only (egress via Cloud NAT). Control-plane endpoint stays public unless locked down via master\_authorized\_networks. | `bool` | `true` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module creates (e.g. <friendly\_name\_prefix>-n8n for the GKE cluster, <friendly\_name\_prefix>-n8n-pg for Cloud SQL). Most commonly an environment (e.g. "sandbox", "prod"), team, or project name. | `string` | n/a | yes |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region for regional resources (GKE, Cloud SQL, Memorystore, subnet). | `string` | `"europe-west1"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete a non-empty bucket (dev only). | `bool` | `false` | no |
| <a name="input_gcs_hmac_access_id"></a> [gcs\_hmac\_access\_id](#input\_gcs\_hmac\_access\_id) | BYO HMAC mode: the HMAC access ID (S3 access key) for the pre-existing key. Required when gcs\_hmac\_service\_account\_email is set. | `string` | `""` | no |
| <a name="input_gcs_hmac_secret"></a> [gcs\_hmac\_secret](#input\_gcs\_hmac\_secret) | BYO HMAC mode: the HMAC secret (S3 secret access key). The module wraps it in the n8n-s3-secret Kubernetes Secret. Ignored if gcs\_hmac\_secret\_name is set. Prefer gcs\_hmac\_secret\_name to keep the raw secret out of Terraform state. | `string` | `""` | no |
| <a name="input_gcs_hmac_secret_name"></a> [gcs\_hmac\_secret\_name](#input\_gcs\_hmac\_secret\_name) | BYO HMAC mode (most locked-down): name of an EXISTING Kubernetes Secret in the n8n namespace holding the HMAC secret under key 'accessSecret'. When set, the module references it directly and creates no Secret, so the raw secret never enters Terraform state. Overrides gcs\_hmac\_secret. | `string` | `""` | no |
| <a name="input_gcs_hmac_service_account_email"></a> [gcs\_hmac\_service\_account\_email](#input\_gcs\_hmac\_service\_account\_email) | BYO HMAC mode: email of a PRE-EXISTING service account that owns an<br/>out-of-band-created HMAC key. When set, the module does NOT create the storage<br/>service account or the HMAC key; it grants this SA objectAdmin on the bucket<br/>and wires the credentials below into n8n. Requires gcs\_hmac\_access\_id and<br/>either gcs\_hmac\_secret or gcs\_hmac\_secret\_name. Empty = default (module<br/>creates the key). | `string` | `""` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location (region or multi-region). | `string` | `"EU"` | no |
| <a name="input_gke_min_master_version"></a> [gke\_min\_master\_version](#input\_gke\_min\_master\_version) | Optional control-plane version prefix (e.g. "1.32"). Empty lets the release channel decide. | `string` | `""` | no |
| <a name="input_gke_release_channel"></a> [gke\_release\_channel](#input\_gke\_release\_channel) | GKE release channel: RAPID, REGULAR, STABLE, or UNSPECIFIED (to pin a version). | `string` | `"REGULAR"` | no |
| <a name="input_https_redirect"></a> [https\_redirect](#input\_https\_redirect) | Redirect HTTP->HTTPS at the LB via a FrontendConfig. Set false while a google\_managed cert is still provisioning (Google needs HTTP reachable), then flip true. | `bool` | `true` | no |
| <a name="input_k8s_service_account_name"></a> [k8s\_service\_account\_name](#input\_k8s\_service\_account\_name) | Kubernetes ServiceAccount the n8n pods run as (annotated for Workload Identity). Matches the n8n Helm chart's serviceAccount name. | `string` | `"n8n"` | no |
| <a name="input_keda_chart_version"></a> [keda\_chart\_version](#input\_keda\_chart\_version) | KEDA Helm chart version to deploy (kedacore/charts). Pinned so every apply installs the same operator version; bump deliberately and re-run the test suite rather than floating to latest. | `string` | `"2.20.1"` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let this module set a PROJECT-LEVEL override that turns OFF the<br/>iam.disableServiceAccountKeyCreation org policy, so the GCS HMAC key can be<br/>created. Default false, the module does not touch org policy.<br/>Set true ONLY IF: (a) your credentials have roles/orgpolicy.policyAdmin (org/<br/>folder-level; a normal project deployer does not), and (b) your org permits<br/>overriding this guardrail. Otherwise disable the policy out-of-band and leave<br/>this false. Requires the orgpolicy.googleapis.com API enabled. | `bool` | `false` | no |
| <a name="input_master_authorized_networks"></a> [master\_authorized\_networks](#input\_master\_authorized\_networks) | CIDRs allowed to reach the control-plane endpoint. Empty = open (dev only); set to your admin CIDRs for a locked-down control plane. | <pre>list(object({<br/>    cidr_block   = string<br/>    display_name = string<br/>  }))</pre> | `[]` | no |
| <a name="input_master_ipv4_cidr"></a> [master\_ipv4\_cidr](#input\_master\_ipv4\_cidr) | CIDR for the GKE control-plane peering range (private cluster). Must not overlap the subnet/pods/services ranges. | `string` | `"172.16.0.0/28"` | no |
| <a name="input_memorystore_auth_enabled"></a> [memorystore\_auth\_enabled](#input\_memorystore\_auth\_enabled) | Enable Redis AUTH. If true, the KEDA worker trigger needs a TriggerAuthentication CRD. | `bool` | `false` | no |
| <a name="input_memorystore_memory_gb"></a> [memorystore\_memory\_gb](#input\_memorystore\_memory\_gb) | Memorystore capacity in GB. | `number` | `1` | no |
| <a name="input_memorystore_redis_version"></a> [memorystore\_redis\_version](#input\_memorystore\_redis\_version) | Memorystore Redis version. | `string` | `"REDIS_7_2"` | no |
| <a name="input_memorystore_tier"></a> [memorystore\_tier](#input\_memorystore\_tier) | Memorystore tier: BASIC (no replica) or STANDARD\_HA. | `string` | `"BASIC"` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | n8n Helm chart version to deploy (n8n-io/n8n-hosting charts/n8n) | `string` | `"1.10.1"` | no |
| <a name="input_n8n_community_packages_prevent_loading"></a> [n8n\_community\_packages\_prevent\_loading](#input\_n8n\_community\_packages\_prevent\_loading) | Prevent installed community packages from being loaded at runtime. Maps to N8N\_COMMUNITY\_PACKAGES\_PREVENT\_LOADING. When true, n8n leaves the community-packages management surface in place but skips loading the package code, which is useful for locking an instance down without uninstalling. Leave false (the default) for community nodes to load and execute. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. | `bool` | `false` | no |
| <a name="input_n8n_database_host"></a> [n8n\_database\_host](#input\_n8n\_database\_host) | External database host. Required when create\_postgres\_instance = false. Ignored otherwise. Use this to pass any external PostgreSQL host. | `string` | `null` | no |
| <a name="input_n8n_database_name"></a> [n8n\_database\_name](#input\_n8n\_database\_name) | n8n database name. | `string` | `"n8n_enterprise"` | no |
| <a name="input_n8n_database_password"></a> [n8n\_database\_password](#input\_n8n\_database\_password) | Password for the external database specified by n8n\_database\_host. Required when create\_postgres\_instance = false. Ignored otherwise (the module generates a random password for its managed Cloud SQL instance). | `string` | `null` | no |
| <a name="input_n8n_database_user"></a> [n8n\_database\_user](#input\_n8n\_database\_user) | n8n database user. | `string` | `"n8n"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). Must match the certificate served for the chosen tls\_mode. | `string` | n/a | yes |
| <a name="input_n8n_execution_concurrency_limit"></a> [n8n\_execution\_concurrency\_limit](#input\_n8n\_execution\_concurrency\_limit) | Maximum concurrent production executions (-1 to disable) | `number` | `100` | no |
| <a name="input_n8n_execution_timeout"></a> [n8n\_execution\_timeout](#input\_n8n\_execution\_timeout) | Default execution timeout in seconds (-1 to disable) | `number` | `7200` | no |
| <a name="input_n8n_execution_timeout_max"></a> [n8n\_execution\_timeout\_max](#input\_n8n\_execution\_timeout\_max) | Maximum execution timeout users can configure in seconds | `number` | `7200` | no |
| <a name="input_n8n_extra_env"></a> [n8n\_extra\_env](#input\_n8n\_extra\_env) | Additional environment variables to inject into all n8n pods (main, worker, and webhook-processor) via the Helm chart's config.extraEnv list. Each entry is an object with name and value string attributes. config.extraEnv is appended last in every container's env list, so by Kubernetes' last-wins rule any name here overrides the chart's value for that name. To prevent silently breaking the deployment, an entry is rejected at plan time when its name collides with a connection, identity, storage, license, or topology variable the module manages: any name starting with DB\_, QUEUE\_, N8N\_RUNNERS\_, N8N\_EXTERNAL\_STORAGE\_S3\_, N8N\_MULTI\_MAIN\_, or AWS\_, plus names like N8N\_ENCRYPTION\_KEY, N8N\_LICENSE\_ACTIVATION\_KEY, N8N\_HOST, WEBHOOK\_URL, and EXECUTIONS\_MODE. Use the dedicated module inputs for those. Do not put secret values here, because they render into the Helm release and are stored in plaintext in Terraform state; instead pass a *\_FILE companion (e.g. a name ending in \_FILE) pointing at a mounted Kubernetes secret, or use n8n credentials. Example: [{name = "N8N\_DEFAULT\_LOCALE", value = "de"}]. | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_helm_timeout"></a> [n8n\_helm\_timeout](#input\_n8n\_helm\_timeout) | Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s. | `number` | `600` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). When it is null (the default), the Helm chart's own default applies, currently the floating `stable` tag, which resolves to whatever n8n version is latest at the time each pod starts. Pin this to a concrete version for reproducible, incremental upgrades and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on an unplanned pod reschedule. See https://docs.n8n.io/2-0-breaking-changes/ for the n8n 2.x migration guide. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_n8n_log_level"></a> [n8n\_log\_level](#input\_n8n\_log\_level) | n8n log level. Maps to the N8N\_LOG\_LEVEL environment variable. One of: silent, error, warn, info, debug, verbose. | `string` | `"info"` | no |
| <a name="input_n8n_log_output"></a> [n8n\_log\_output](#input\_n8n\_log\_output) | n8n log output destination(s). Maps to the N8N\_LOG\_OUTPUT environment variable. Comma-separated subset of: console, file (e.g. "console", "file", "console,file"). Note: this variable does NOT control log *format*, setting an invalid value (e.g. "json") leaves Winston with no transport and silently drops all logs. To emit JSON-formatted logs, configure n8n's logging block separately; this env var only selects destinations. | `string` | `"console"` | no |
| <a name="input_n8n_log_streaming_destinations"></a> [n8n\_log\_streaming\_destinations](#input\_n8n\_log\_streaming\_destinations) | List of log streaming destination objects, JSON-encoded into N8N\_LOG\_STREAMING\_DESTINATIONS. Each entry must set type to webhook, syslog, or sentry, plus the type-specific fields documented at https://docs.n8n.io/log-streaming/#configure-using-environment-variables (common fields: label, enabled, subscribedEvents, anonymizeAuditMessages, circuitBreaker). Typed as any because the three destination shapes differ structurally. Marked sensitive because webhook headers and Sentry DSNs typically carry credentials, note the value is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). Ignored when n8n\_log\_streaming\_managed\_by\_env = false. | `any` | `[]` | no |
| <a name="input_n8n_log_streaming_managed_by_env"></a> [n8n\_log\_streaming\_managed\_by\_env](#input\_n8n\_log\_streaming\_managed\_by\_env) | Manage n8n's Enterprise log streaming destinations from environment variables instead of the UI. Maps to N8N\_LOG\_STREAMING\_MANAGED\_BY\_ENV. When true, n8n applies n8n\_log\_streaming\_destinations on every startup and locks the Log Streaming UI controls read-only. When false (the default), no log streaming env vars are emitted and destinations stay UI-managed; flipping back to false keeps the last applied destinations but restores UI write access. Requires n8n >= 2.19.0 and an Enterprise license that includes log streaming. See https://docs.n8n.io/log-streaming/ for the underlying n8n contract. | `bool` | `false` | no |
| <a name="input_n8n_main_cpu_limit"></a> [n8n\_main\_cpu\_limit](#input\_n8n\_main\_cpu\_limit) | CPU limit for n8n main pods (e.g. 2000m, 1000m) | `string` | `"2000m"` | no |
| <a name="input_n8n_main_cpu_request"></a> [n8n\_main\_cpu\_request](#input\_n8n\_main\_cpu\_request) | CPU request for n8n main pods (e.g. 1000m, 500m) | `string` | `"1000m"` | no |
| <a name="input_n8n_main_hpa_cpu_threshold"></a> [n8n\_main\_hpa\_cpu\_threshold](#input\_n8n\_main\_hpa\_cpu\_threshold) | Target average CPU utilization (%) that triggers scaling of n8n main pods. | `number` | `60` | no |
| <a name="input_n8n_main_hpa_max_replicas"></a> [n8n\_main\_hpa\_max\_replicas](#input\_n8n\_main\_hpa\_max\_replicas) | Maximum replicas for n8n main pods. HPA will not scale above this. | `number` | `20` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replicas for n8n main pods. HPA will not scale below this. | `number` | `2` | no |
| <a name="input_n8n_main_memory_limit"></a> [n8n\_main\_memory\_limit](#input\_n8n\_main\_memory\_limit) | Memory limit for n8n main pods (e.g. 4Gi, 2Gi) | `string` | `"4Gi"` | no |
| <a name="input_n8n_main_memory_request"></a> [n8n\_main\_memory\_request](#input\_n8n\_main\_memory\_request) | Memory request for n8n main pods (e.g. 2Gi, 1Gi) | `string` | `"2Gi"` | no |
| <a name="input_n8n_metrics_enabled"></a> [n8n\_metrics\_enabled](#input\_n8n\_metrics\_enabled) | Enable n8n's built-in Prometheus metrics endpoint. When true, the module appends N8N\_METRICS=true to the n8n Helm release's config.extraEnv, which the chart applies to every n8n container (main, worker, webhook processor). n8n exposes /metrics on its existing HTTP port (5678), the same port and service the chart already publishes for the UI/API. The n8n Helm chart at the currently pinned version (see n8n\_chart\_version) exposes no top-level metrics / serviceMonitor block of its own, so this toggle is intentionally env-var-only. Scrape configuration (Prometheus scrape annotations or a ServiceMonitor CR) is left to the caller's monitoring stack, in practice the main pod's Service is the meaningful scrape target. Defaults to false; when false the env var is omitted entirely so n8n's own defaults apply. | `bool` | `false` | no |
| <a name="input_n8n_otel_enabled"></a> [n8n\_otel\_enabled](#input\_n8n\_otel\_enabled) | Master switch for n8n's OpenTelemetry workflow + node tracing. When true, the module sets N8N\_OTEL\_ENABLED=true on all n8n containers (main, worker, webhook processor) via the Helm release's config.extraEnv block. When false (the default), no OpenTelemetry env vars are emitted and the SDK is not loaded. The OpenTelemetry collector / Jaeger receiver is out of scope for this module, deploy it separately and point n8n\_otel\_exporter\_otlp\_endpoint at it. See https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/ for the underlying n8n contract. | `bool` | `false` | no |
| <a name="input_n8n_otel_exporter_otlp_endpoint"></a> [n8n\_otel\_exporter\_otlp\_endpoint](#input\_n8n\_otel\_exporter\_otlp\_endpoint) | Base URL of the OTLP HTTP endpoint to export traces to (e.g. http://otel-collector.observability.svc.cluster.local:4318 for an in-cluster collector). When set, maps to N8N\_OTEL\_EXPORTER\_OTLP\_ENDPOINT. n8n appends /v1/traces to this value internally, so point at the base URL, not the traces path. Leave null to use n8n's default (http://localhost:4318), which only works if a sidecar collector is colocated in each n8n pod (this module does not deploy one). Ignored when n8n\_otel\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_otel_exporter_otlp_headers"></a> [n8n\_otel\_exporter\_otlp\_headers](#input\_n8n\_otel\_exporter\_otlp\_headers) | Comma-separated list of key=value pairs sent as HTTP headers with each OTLP request (e.g. 'authorization=Bearer <token>,x-tenant=acme'). Use this for collector authentication or multi-tenant routing. Maps to N8N\_OTEL\_EXPORTER\_OTLP\_HEADERS. Leave null to send no extra headers. Marked sensitive so the value is redacted from CLI and plan output, but note it is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). The chart's config.extraEnv does not support secretKeyRef, so restrict access to state and the n8n namespace accordingly. Ignored when n8n\_otel\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_otel_exporter_service_name"></a> [n8n\_otel\_exporter\_service\_name](#input\_n8n\_otel\_exporter\_service\_name) | Value of the service.name resource attribute on exported spans. Maps to N8N\_OTEL\_EXPORTER\_SERVICE\_NAME. Leave null to use n8n's default ('n8n'). Set this to differentiate multiple n8n deployments sending traces to the same collector (e.g. 'n8n-prod', 'n8n-staging'). Ignored when n8n\_otel\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_otel_traces_include_node_spans"></a> [n8n\_otel\_traces\_include\_node\_spans](#input\_n8n\_otel\_traces\_include\_node\_spans) | Whether to emit a node.execute span for each node execution. Maps to N8N\_OTEL\_TRACES\_INCLUDE\_NODE\_SPANS. Leave null to use n8n's default (true, one span per node per execution). Set to false to export workflow-level spans only, a common volume-reduction lever for workflows with many small nodes. Ignored when n8n\_otel\_enabled = false. | `bool` | `null` | no |
| <a name="input_n8n_otel_traces_inject_outbound"></a> [n8n\_otel\_traces\_inject\_outbound](#input\_n8n\_otel\_traces\_inject\_outbound) | Whether n8n's HTTP-helper-based nodes (HTTP Request and similar) inject W3C traceparent / tracestate headers into outbound requests. Maps to N8N\_OTEL\_TRACES\_INJECT\_OUTBOUND. Leave null to use n8n's default (true, propagate context to downstream services). Set to false when calling external systems that misbehave on unexpected headers, or when you don't want trace context leaving your boundary. Ignored when n8n\_otel\_enabled = false. | `bool` | `null` | no |
| <a name="input_n8n_otel_traces_production_only"></a> [n8n\_otel\_traces\_production\_only](#input\_n8n\_otel\_traces\_production\_only) | Whether to export traces for production workflow executions only. Maps to N8N\_OTEL\_TRACES\_PRODUCTION\_ONLY. Leave null to use n8n's default (true, only production executions are traced). Set to false to also trace manual/test executions run from the editor, which helps while developing instrumentation but is noisy in production. Ignored when n8n\_otel\_enabled = false. | `bool` | `null` | no |
| <a name="input_n8n_otel_traces_sample_rate"></a> [n8n\_otel\_traces\_sample\_rate](#input\_n8n\_otel\_traces\_sample\_rate) | Fraction of traces to export, between 0 and 1 inclusive. Maps to N8N\_OTEL\_TRACES\_SAMPLE\_RATE. n8n uses a trace-ID-ratio sampler, so the same trace ID is either fully sampled or fully dropped across all spans. Leave null to use n8n's default (1.0, every trace exported). Lower for high-volume installs where the collector or backend can't handle every workflow execution as a trace. Ignored when n8n\_otel\_enabled = false. | `number` | `null` | no |
| <a name="input_n8n_personalization_enabled"></a> [n8n\_personalization\_enabled](#input\_n8n\_personalization\_enabled) | Whether n8n asks users personalization survey questions and tailors content/recommendations based on the answers. Maps to N8N\_PERSONALIZATION\_ENABLED. When false, sets N8N\_PERSONALIZATION\_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default, note that explicitly setting true emits no env var (n8n's default already applies). Set to false to skip the personalization survey, e.g. on shared or ephemeral instances. | `bool` | `true` | no |
| <a name="input_n8n_prestop_sleep"></a> [n8n\_prestop\_sleep](#input\_n8n\_prestop\_sleep) | Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM, do not lower below 10. | `number` | `10` | no |
| <a name="input_n8n_pruning_max_age"></a> [n8n\_pruning\_max\_age](#input\_n8n\_pruning\_max\_age) | Maximum age of execution records to retain, in hours (336 = 14 days) | `number` | `336` | no |
| <a name="input_n8n_pruning_max_count"></a> [n8n\_pruning\_max\_count](#input\_n8n\_pruning\_max\_count) | Maximum number of execution records to retain (0 = no limit) | `number` | `10000` | no |
| <a name="input_n8n_reinstall_missing_packages"></a> [n8n\_reinstall\_missing\_packages](#input\_n8n\_reinstall\_missing\_packages) | Reinstall community packages that are recorded in the database but missing from a pod's local filesystem at startup. Maps to N8N\_REINSTALL\_MISSING\_PACKAGES. n8n stores installed community packages on the pod's filesystem, which is ephemeral in Kubernetes, so a rescheduled or newly scaled-up worker comes up without them and nodes installed via the UI fail to load on that pod. Enabling this makes every pod (main, worker, and webhook-processor) reinstall the recorded packages on boot, which is what lets community nodes work reliably in queue mode. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. | `bool` | `false` | no |
| <a name="input_n8n_task_runner_auto_shutdown_timeout"></a> [n8n\_task\_runner\_auto\_shutdown\_timeout](#input\_n8n\_task\_runner\_auto\_shutdown\_timeout) | Seconds of inactivity before the runner process shuts down. Set to 0 to disable. | `number` | `15` | no |
| <a name="input_n8n_task_runner_cpu_limit"></a> [n8n\_task\_runner\_cpu\_limit](#input\_n8n\_task\_runner\_cpu\_limit) | CPU limit for task runner sidecar containers (e.g. 1, 2000m) | `string` | `"1"` | no |
| <a name="input_n8n_task_runner_cpu_request"></a> [n8n\_task\_runner\_cpu\_request](#input\_n8n\_task\_runner\_cpu\_request) | CPU request for task runner sidecar containers (e.g. 200m, 500m) | `string` | `"200m"` | no |
| <a name="input_n8n_task_runner_memory_limit"></a> [n8n\_task\_runner\_memory\_limit](#input\_n8n\_task\_runner\_memory\_limit) | Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_n8n_task_runner_memory_request"></a> [n8n\_task\_runner\_memory\_request](#input\_n8n\_task\_runner\_memory\_request) | Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi) | `string` | `"512Mi"` | no |
| <a name="input_n8n_task_runner_python_enabled"></a> [n8n\_task\_runner\_python\_enabled](#input\_n8n\_task\_runner\_python\_enabled) | Enable the native Python runner (beta). Required for Python code execution in workflows. | `bool` | `true` | no |
| <a name="input_n8n_task_runner_request_timeout"></a> [n8n\_task\_runner\_request\_timeout](#input\_n8n\_task\_runner\_request\_timeout) | Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N\_RUNNERS\_TASK\_REQUEST\_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar). | `number` | `300` | no |
| <a name="input_n8n_task_runners_enabled"></a> [n8n\_task\_runners\_enabled](#input\_n8n\_task\_runners\_enabled) | Enable task runner sidecars for isolated JavaScript and Python code execution | `bool` | `true` | no |
| <a name="input_n8n_templates_enabled"></a> [n8n\_templates\_enabled](#input\_n8n\_templates\_enabled) | Enable n8n's workflow templates and template suggestions. Maps to N8N\_TEMPLATES\_ENABLED. When false, sets N8N\_TEMPLATES\_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default, note that explicitly setting true emits no env var (n8n's default already applies). Set to false to hide the templates library, e.g. when enforcing curated internal workflows. | `bool` | `true` | no |
| <a name="input_n8n_termination_grace_period"></a> [n8n\_termination\_grace\_period](#input\_n8n\_termination\_grace\_period) | Seconds Kubernetes waits after SIGTERM before force-killing pods. MINIMUM, do not lower below 60. Workers need time to finish in-flight executions before being terminated. | `number` | `60` | no |
| <a name="input_n8n_timezone"></a> [n8n\_timezone](#input\_n8n\_timezone) | Timezone for n8n (e.g. UTC, America/New\_York, Europe/London) | `string` | `"UTC"` | no |
| <a name="input_n8n_webhook_cpu_limit"></a> [n8n\_webhook\_cpu\_limit](#input\_n8n\_webhook\_cpu\_limit) | CPU limit for n8n webhook processor pods (e.g. 800m, 1000m) | `string` | `"800m"` | no |
| <a name="input_n8n_webhook_cpu_request"></a> [n8n\_webhook\_cpu\_request](#input\_n8n\_webhook\_cpu\_request) | CPU request for n8n webhook processor pods (e.g. 300m, 500m) | `string` | `"300m"` | no |
| <a name="input_n8n_webhook_hpa_cpu_threshold"></a> [n8n\_webhook\_hpa\_cpu\_threshold](#input\_n8n\_webhook\_hpa\_cpu\_threshold) | Target average CPU utilization (%) that triggers scaling of n8n webhook pods. | `number` | `65` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Maximum replicas for n8n webhook processor pods. HPA will not scale above this. | `number` | `50` | no |
| <a name="input_n8n_webhook_hpa_min_replicas"></a> [n8n\_webhook\_hpa\_min\_replicas](#input\_n8n\_webhook\_hpa\_min\_replicas) | Minimum replicas for n8n webhook processor pods. HPA will not scale below this. | `number` | `2` | no |
| <a name="input_n8n_webhook_memory_limit"></a> [n8n\_webhook\_memory\_limit](#input\_n8n\_webhook\_memory\_limit) | Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_n8n_webhook_memory_request"></a> [n8n\_webhook\_memory\_request](#input\_n8n\_webhook\_memory\_request) | Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi) | `string` | `"512Mi"` | no |
| <a name="input_n8n_webhook_url"></a> [n8n\_webhook\_url](#input\_n8n\_webhook\_url) | Public HTTPS base URL used for webhook callbacks (e.g. https://webhooks.example.com). Defaults to https://<n8n\_domain> when not set. Override when webhooks are served from a different host than the n8n UI. | `string` | `null` | no |
| <a name="input_n8n_worker_concurrency"></a> [n8n\_worker\_concurrency](#input\_n8n\_worker\_concurrency) | Number of jobs each worker pod can process simultaneously | `number` | `10` | no |
| <a name="input_n8n_worker_cpu_limit"></a> [n8n\_worker\_cpu\_limit](#input\_n8n\_worker\_cpu\_limit) | CPU limit for n8n worker pods (e.g. 1000m, 2000m) | `string` | `"1000m"` | no |
| <a name="input_n8n_worker_cpu_request"></a> [n8n\_worker\_cpu\_request](#input\_n8n\_worker\_cpu\_request) | CPU request for n8n worker pods (e.g. 500m, 1000m) | `string` | `"500m"` | no |
| <a name="input_n8n_worker_keda_jobs_per_replica"></a> [n8n\_worker\_keda\_jobs\_per\_replica](#input\_n8n\_worker\_keda\_jobs\_per\_replica) | Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue\_depth / jobs\_per\_replica) replicas. | `number` | `5` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Maximum worker replicas KEDA may scale to. | `number` | `10` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty. | `number` | `1` | no |
| <a name="input_n8n_worker_memory_limit"></a> [n8n\_worker\_memory\_limit](#input\_n8n\_worker\_memory\_limit) | Memory limit for n8n worker pods (e.g. 2Gi, 4Gi) | `string` | `"2Gi"` | no |
| <a name="input_n8n_worker_memory_request"></a> [n8n\_worker\_memory\_request](#input\_n8n\_worker\_memory\_request) | Memory request for n8n worker pods (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Kubernetes namespace to deploy n8n into | `string` | `"n8n"` | no |
| <a name="input_node_disk_size_gb"></a> [node\_disk\_size\_gb](#input\_node\_disk\_size\_gb) | Node boot disk size in GB. | `number` | `100` | no |
| <a name="input_node_disk_type"></a> [node\_disk\_type](#input\_node\_disk\_type) | Node boot disk type (pd-standard, pd-balanced, pd-ssd). | `string` | `"pd-balanced"` | no |
| <a name="input_node_machine_type"></a> [node\_machine\_type](#input\_node\_machine\_type) | Node machine type. | `string` | `"e2-standard-4"` | no |
| <a name="input_node_max_per_zone"></a> [node\_max\_per\_zone](#input\_node\_max\_per\_zone) | Autoscaling maximum nodes PER ZONE (total max is roughly this x number of zones). | `number` | `2` | no |
| <a name="input_node_min_per_zone"></a> [node\_min\_per\_zone](#input\_node\_min\_per\_zone) | Autoscaling minimum nodes PER ZONE. A regional cluster spans ~3 zones, so total min is roughly this x3. | `number` | `1` | no |
| <a name="input_pods_cidr"></a> [pods\_cidr](#input\_pods\_cidr) | Secondary range for GKE pods (VPC-native / alias IPs). | `string` | `"10.20.0.0/16"` | no |
| <a name="input_postgres_availability_type"></a> [postgres\_availability\_type](#input\_postgres\_availability\_type) | REGIONAL for HA (failover replica), ZONAL for single-zone. | `string` | `"REGIONAL"` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_disk_size"></a> [postgres\_disk\_size](#input\_postgres\_disk\_size) | Cloud SQL data disk size in GB. | `number` | `50` | no |
| <a name="input_postgres_edition"></a> [postgres\_edition](#input\_postgres\_edition) | Cloud SQL edition. ENTERPRISE supports shared-core/legacy tiers like db-g1-small (cheap, dev). ENTERPRISE\_PLUS requires db-perf-optimized-N-* tiers. Pinned because some projects/orgs default new instances to ENTERPRISE\_PLUS, which rejects db-g1-small. | `string` | `"ENTERPRISE"` | no |
| <a name="input_postgres_machine_type"></a> [postgres\_machine\_type](#input\_postgres\_machine\_type) | Cloud SQL machine tier. ENTERPRISE: e.g. db-g1-small, db-custom-2-7680. ENTERPRISE\_PLUS: e.g. db-perf-optimized-N-2. Must be compatible with postgres\_edition. | `string` | `"db-g1-small"` | no |
| <a name="input_postgres_version"></a> [postgres\_version](#input\_postgres\_version) | Cloud SQL Postgres version. | `string` | `"POSTGRES_16"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID to deploy into. | `string` | n/a | yes |
| <a name="input_psa_cleanup_destroy_duration"></a> [psa\_cleanup\_destroy\_duration](#input\_psa\_cleanup\_destroy\_duration) | How long to pause on destroy after Cloud SQL/Memorystore are deleted before deleting the Private Services Access peering, giving GCP's backend time to release its hold on the connection. GCP does not report when the release completes, and the observed lag varies widely (minutes to well over an hour). If destroy still fails with 'Producer services ... are still using this connection', either raise this or use the compute-level peering-delete escape hatch documented in README.md ('Teardown'). Accepts Go duration syntax (e.g. "3m", "15m", "1h"). | `string` | `"3m"` | no |
| <a name="input_psa_prefix_length"></a> [psa\_prefix\_length](#input\_psa\_prefix\_length) | Prefix length for the Private Services Access range that Cloud SQL / Memorystore peer into. | `number` | `16` | no |
| <a name="input_services_cidr"></a> [services\_cidr](#input\_services\_cidr) | Secondary range for GKE services (VPC-native / alias IPs). | `string` | `"10.30.0.0/20"` | no |
| <a name="input_subnet_cidr"></a> [subnet\_cidr](#input\_subnet\_cidr) | Primary CIDR for the node subnet. | `string` | `"10.10.0.0/20"` | no |
| <a name="input_tls_cert_pem"></a> [tls\_cert\_pem](#input\_tls\_cert\_pem) | PEM certificate chain (tls\_mode = custom), e.g. a Cloudflare Origin CA cert. | `string` | `""` | no |
| <a name="input_tls_key_pem"></a> [tls\_key\_pem](#input\_tls\_key\_pem) | PEM private key (tls\_mode = custom). | `string` | `""` | no |
| <a name="input_tls_mode"></a> [tls\_mode](#input\_tls\_mode) | How the LB gets its cert (base module, provider-clean):<br/>  - "google\_managed" : ManagedCertificate CRD, auto-renew. DEFAULT. Validated end to end; the DNS A-record must point at the LB static IP before the cert can provision.<br/>  - "custom"         : bring your own PEM (tls\_cert\_pem/tls\_key\_pem), e.g. a Cloudflare Origin CA cert, uploaded as a pre-shared cert.<br/>  - "secret"         : the gce Ingress consumes an existing k8s TLS Secret (tls\_secret\_name). This is how examples/cloudflare wires Let's Encrypt via cert-manager.<br/>  - "self\_signed"    : instant cert with a browser warning, for smoke tests before DNS is live. | `string` | `"google_managed"` | no |
| <a name="input_tls_secret_name"></a> [tls\_secret\_name](#input\_tls\_secret\_name) | Name of an existing Kubernetes TLS Secret the Ingress should use (tls\_mode = secret). Populated by an external issuer such as cert-manager in examples/cloudflare. | `string` | `"n8n-tls"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | GCS bucket used for n8n binary storage. |
| <a name="output_gcs_hmac_access_id"></a> [gcs\_hmac\_access\_id](#output\_gcs\_hmac\_access\_id) | GCS HMAC access key ID for the n8n S3-compatible binary storage driver (module-created or caller-supplied in BYO mode). |
| <a name="output_gcs_hmac_secret"></a> [gcs\_hmac\_secret](#output\_gcs\_hmac\_secret) | GCS HMAC secret for the n8n S3-compatible binary storage driver. Null in BYO mode when supplied via an existing Secret (gcs\_hmac\_secret\_name). |
| <a name="output_gke_cluster_ca_certificate"></a> [gke\_cluster\_ca\_certificate](#output\_gke\_cluster\_ca\_certificate) | Base64-encoded GKE cluster CA. Pass to kubernetes/helm providers as cluster\_ca\_certificate (after base64decode). |
| <a name="output_gke_cluster_endpoint"></a> [gke\_cluster\_endpoint](#output\_gke\_cluster\_endpoint) | GKE control-plane endpoint. Pass to the kubernetes/helm providers as host (https://<endpoint>). |
| <a name="output_gke_cluster_name"></a> [gke\_cluster\_name](#output\_gke\_cluster\_name) | GKE cluster name. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_lb_ingress_ip"></a> [lb\_ingress\_ip](#output\_lb\_ingress\_ip) | IP the Ingress reports once the LB is provisioned (should match static\_ip). |
| <a name="output_memorystore_host"></a> [memorystore\_host](#output\_memorystore\_host) | Memorystore Redis host (VPC-internal). |
| <a name="output_n8n_database_password"></a> [n8n\_database\_password](#output\_n8n\_database\_password) | Database password. Module-managed when create\_postgres\_instance = true, else var.n8n\_database\_password. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key. Back this up; losing it makes all stored credentials unreadable. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once DNS propagates and the cert is active |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
| <a name="output_postgres_connection_name"></a> [postgres\_connection\_name](#output\_postgres\_connection\_name) | Cloud SQL instance connection name (project:region:instance). |
| <a name="output_postgres_private_ip"></a> [postgres\_private\_ip](#output\_postgres\_private\_ip) | Cloud SQL private IP (VPC-internal). |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | Reserved global static IP of the L7 load balancer. Point n8n\_domain (an A record) at this. The base module creates the record when dns\_managed\_zone is set; otherwise create it in your DNS provider (as examples/cloudflare does). |
| <a name="output_workload_identity_service_account"></a> [workload\_identity\_service\_account](#output\_workload\_identity\_service\_account) | Google service account the n8n pods impersonate via Workload Identity. |
<!-- END_TF_DOCS -->

