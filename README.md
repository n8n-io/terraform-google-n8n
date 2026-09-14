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

Every layer above is independently ownable. A static `create_*` (or
`install_*`) switch per layer, network, GKE, PostgreSQL, Redis, GCS bucket,
namespace, ingress, application autoscaling, and the KEDA/StorageClass
controller submodule, lets a platform team bring an existing resource instead
of letting the module create it, while the module keeps wiring n8n against
the same ownership-neutral outputs either way. See
[`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md)
for the full ownership matrix, required references, prerequisite
attestations, and security boundary.

---

## Usage

The base module is provider-clean and creates its own VPC. The recommended path is to configure it from an example root:

- **[`examples/small`](./examples/small)**: the default path (Google Cloud DNS + a Google-managed TLS certificate).
- **[`examples/medium`](./examples/medium)** / **[`examples/large`](./examples/large)**: scaled-up reference architectures (HA database, bigger nodes, higher autoscaling ceilings).
- **[`examples/cloudflare`](./examples/cloudflare)**: Cloudflare DNS + auto-renewing Let's Encrypt via cert-manager (the validated TLS path).
- **[`examples/godaddy`](./examples/godaddy)**: GoDaddy DNS + a Google-managed certificate.
- **[`examples/customer-managed-cluster`](./examples/customer-managed-cluster)**: deploys onto an existing regional GKE cluster instead of creating one.
- **[`examples/customer-managed-redis`](./examples/customer-managed-redis)**: connects to an external Redis-compatible service instead of creating Memorystore.
- **[`examples/customer-managed-gcs`](./examples/customer-managed-gcs)**: uses an existing GCS bucket and HMAC identity instead of creating them.
- **[`examples/customer-managed-everything`](./examples/customer-managed-everything)**: every ownership switch flipped: network, GKE, Cloud SQL, Redis, GCS bucket, namespace, ingress, HPAs, worker KEDA, and the KEDA controller install.

See [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md) for the ownership contract these last four examples exercise.

If `terraform apply` fails on a `helm_release` or a `ManagedCertificate` stalls in `Provisioning`, see [`docs/troubleshooting.md`](./docs/troubleshooting.md).

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

  friendly_name_prefix = "myteam"
  project_id           = "my-project"
  gcp_region           = "europe-west1"
  n8n_fqdn             = "n8n.example.com"
  n8n_license_key      = var.n8n_license_key

  # Optional: let the module manage the DNS A-record in Cloud DNS.
  cloud_dns_zone_name = "example-com"
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

DNS: the base module can manage a Google Cloud DNS record (`cloud_dns_zone_name`); other providers (Cloudflare, GoDaddy) manage their own record against the `static_ip` output.

---

## Key inputs

| Variable | Description |
|---|---|
| `project_id` | GCP project ID (required). |
| `gcp_region` | Region (e.g. `us-east4`, `europe-west1`). |
| `friendly_name_prefix` | Prefix used to derive the name of every Google Cloud resource (<= 20 chars). |
| `n8n_fqdn` | Hostname n8n is served on. |
| `n8n_license_key` | n8n Enterprise activation key. |
| `gcs_location` | GCS bucket location; keep near `gcp_region` (`US` / `EU` / a region). |
| `tls_mode` | Certificate source (table above). |
| `manage_sa_key_org_policy` | Opt-in org-policy override for the HMAC key (see Prerequisites). Default `false`. |
| `gcs_hmac_service_account_email` | BYO HMAC mode for locked-down orgs: supply a pre-existing SA (+ `gcs_hmac_access_id` and `gcs_hmac_secret_name`/`gcs_hmac_secret`) and the module skips HMAC-key creation. Default empty. |
| `redis_auth_enabled` | Enable Redis AUTH (default off); the module wires the KEDA `TriggerAuthentication` when on. |

Cloud SQL, Memorystore, node-pool sizing, autoscaling bounds, pruning, and OpenTelemetry are all configurable, see `variables.tf` / `variables_gcp.tf`. Every `create_*`/`existing_*` ownership input is documented in [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md).

## Key outputs

`static_ip`, `n8n_url`, `gke_cluster_name`, `gke_cluster_endpoint`, `kubectl_config_command`, `postgres_private_ip`, `redis_host`, `gcs_bucket_name`. Sensitive: `n8n_database_password`, `n8n_encryption_key`, `gcs_hmac_access_id`, `gcs_hmac_secret` (retrieve with `terraform output -raw <name>`).

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

- **Teardown.** `gke_deletion_protection` and `postgres_deletion_protection`
  default to `true`, so `terraform destroy` refuses until the protection flags are
  flipped on the *live* resources first. Setting the vars to `false` on the destroy
  command alone is not enough (the provider still reads protection from the existing
  resource), you must `apply` the change first:

  ```bash
  # 1. flip protection on the live cluster + SQL instance, and allow bucket destroy
  terraform apply -auto-approve \
    -var gke_deletion_protection=false \
    -var postgres_deletion_protection=false \
    -var gcs_force_destroy=true
  # 2. then destroy (repeat the same -var flags)
  terraform destroy -auto-approve \
    -var gke_deletion_protection=false \
    -var postgres_deletion_protection=false \
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
    --network=<friendly_name_prefix>-n8n-vpc --project=<project_id>
  terraform destroy -auto-approve \
    -var gke_deletion_protection=false \
    -var postgres_deletion_protection=false \
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

- **Multi-region / cross-region deployments.** One module instance is one
  region, one GKE cluster, one n8n deployment. Cross-region replication of the
  database or GCS binary storage is the caller's problem.
- **Backup/DR automation beyond Cloud SQL backups.** The module enables Cloud
  SQL automated backups and point-in-time recovery. It does not automate restore
  drills, cross-region backup copy, or n8n encryption-key escrow. The
  `n8n_encryption_key` output is emitted at apply time; backing it up is the
  operator's job and the single most important thing not to forget. A restore
  or clone onto a module-managed instance does not carry over the original
  encryption key either, see
  [Restored/cloned database encryption-key continuity](./docs/customer-managed-infrastructure.md#restoredcloned-database-encryption-key-continuity).
- **Bundled observability.** The module installs KEDA for worker autoscaling and
  supports OpenTelemetry trace export, but does not install Prometheus, Grafana,
  Loki, or a collector. Point `n8n_otel_exporter_otlp_endpoint` at your own.

Bring-your-own VPC, GKE cluster, PostgreSQL, Redis, GCS bucket, namespace,
ingress, and private image registries/chart mirrors (air-gapped-friendly) are
all now supported, see
[`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md).

## Reference

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
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.0 |
| <a name="provider_google-beta"></a> [google-beta](#provider\_google-beta) | ~> 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.12 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | ~> 4.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_controllers"></a> [controllers](#module\_controllers) | ./modules/controllers | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google-beta_google_project_service_identity.gcs](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_project_service_identity) | resource |
| [google-beta_google_project_service_identity.postgres](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_project_service_identity) | resource |
| [google-beta_google_project_service_identity.redis](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_project_service_identity) | resource |
| [google_compute_global_address.lb](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_global_address.psa](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_network.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_router.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router) | resource |
| [google_compute_router_nat.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat) | resource |
| [google_compute_security_policy.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy) | resource |
| [google_compute_ssl_certificate.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_ssl_certificate) | resource |
| [google_compute_subnetwork.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_container_cluster.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster) | resource |
| [google_container_node_pool.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool) | resource |
| [google_dns_record_set.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_kms_crypto_key.gcs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key.postgres](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key.redis](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key_iam_member.gcs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_crypto_key_iam_member.postgres](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_crypto_key_iam_member.redis](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_key_ring.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_key_ring) | resource |
| [google_org_policy_policy.disable_sa_key_creation](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/org_policy_policy) | resource |
| [google_project_iam_member.n8n_cloudsql_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_redis_instance.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/redis_instance) | resource |
| [google_secret_manager_secret_iam_member.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
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
| [kubernetes_secret.n8n_license](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_redis_tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_redis_username](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_s3](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.redis_auth](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_service_account_v1.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [random_id.n8n_encryption_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_password.db_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.task_runner_token](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.wait_for_lb_cleanup](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.wait_for_psa_cleanup](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [tls_private_key.self_signed](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.self_signed](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |
| [google_compute_machine_types.gke](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_machine_types) | data source |
| [google_compute_zones.gke](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_zones) | data source |
| [google_container_cluster.existing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/container_cluster) | data source |
| [google_project.n8n](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [google_sql_database_instance.restore_source](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/sql_database_instance) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloud_dns_zone_name"></a> [cloud\_dns\_zone\_name](#input\_cloud\_dns\_zone\_name) | Google Cloud DNS managed-zone name to create the A record in. Empty string means the module does not manage DNS (you point n8n\_fqdn at the static IP output yourself, as examples/cloudflare does). | `string` | `""` | no |
| <a name="input_common_labels"></a> [common\_labels](#input\_common\_labels) | Common labels merged into every taggable Google Cloud resource the module creates. Built-in module labels win on key collision. | `map(string)` | `{}` | no |
| <a name="input_create_gcs_bucket"></a> [create\_gcs\_bucket](#input\_create\_gcs\_bucket) | When true (the default), the module creates and manages the GCS bucket used for n8n binary storage. Set to false to use an existing bucket; existing\_gcs\_bucket\_name must then be supplied. HMAC identity ownership (gcs\_hmac\_service\_account\_email) is independent of bucket ownership: the module still grants bucket-scoped IAM to the effective HMAC identity. | `bool` | `true` | no |
| <a name="input_create_gcs_kms_key"></a> [create\_gcs\_kms\_key](#input\_create\_gcs\_kms\_key) | When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create\_kms\_key\_ring/existing\_kms\_key\_ring\_id) and configures the module-managed GCS bucket to use it as its default customer-managed encryption key. Mutually exclusive with existing\_gcs\_kms\_key\_id. Ignored when create\_gcs\_bucket = false. Defaults to false (Google-managed encryption). The created key is protected by lifecycle prevent\_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key. | `bool` | `false` | no |
| <a name="input_create_gke"></a> [create\_gke](#input\_create\_gke) | When true (the default), the module creates and manages the GKE cluster, node pool, node service account, and node IAM bindings. Set to false to deploy onto an existing regional GKE cluster; existing\_gke\_cluster\_name and existing\_gke\_prerequisites\_attestation must then be supplied. | `bool` | `true` | no |
| <a name="input_create_ingress"></a> [create\_ingress](#input\_create\_ingress) | When true (the default), the module creates and manages the global load-balancer address, Cloud DNS record, GKE ingress, BackendConfig, FrontendConfig, TLS resources, and load-balancer teardown delay. Set to false to let the caller own ingress, DNS, and TLS; use the module's route and service outputs to build a compatible ingress. | `bool` | `true` | no |
| <a name="input_create_kms_key_ring"></a> [create\_kms\_key\_ring](#input\_create\_kms\_key\_ring) | When true, the module creates and manages a Cloud KMS key ring to host module-created CMEK keys (create\_postgres\_kms\_key, create\_redis\_kms\_key, create\_gcs\_kms\_key). Ignored unless at least one service's create\_*\_kms\_key switch is true. Set to false and supply existing\_kms\_key\_ring\_id to host module-created keys in an existing key ring instead. Defaults to false. | `bool` | `false` | no |
| <a name="input_create_namespace"></a> [create\_namespace](#input\_create\_namespace) | When true (the default), the module creates the n8n\_kube\_namespace namespace. Set to false to deploy into an existing namespace the module does not read, create, change, or delete. | `bool` | `true` | no |
| <a name="input_create_network"></a> [create\_network](#input\_create\_network) | When true (the default), the module creates and manages the VPC, subnetwork, secondary ranges, Cloud Router, and Cloud NAT. Set to false to attach to an existing network; existing\_network\_name, existing\_subnetwork\_name, existing\_pods\_range\_name, and existing\_services\_range\_name must then be supplied. | `bool` | `true` | no |
| <a name="input_create_pd_balanced_storage_class"></a> [create\_pd\_balanced\_storage\_class](#input\_create\_pd\_balanced\_storage\_class) | When true (the default), the module creates an explicit pd-balanced StorageClass via modules/controllers for stateful workloads that run beside n8n (n8n itself is stateless). Set to false to omit it, e.g. when the caller already defines an equivalent StorageClass. | `bool` | `true` | no |
| <a name="input_create_postgres_instance"></a> [create\_postgres\_instance](#input\_create\_postgres\_instance) | When true (the default), the module creates and manages a Cloud SQL PostgreSQL instance, its database, its user, and its Cloud SQL-specific IAM bindings. Set to false to use an external database; n8n\_database\_host and exactly one of n8n\_database\_password / n8n\_database\_password\_secret\_ref must then be supplied. Kept as a static boolean rather than inferred from n8n\_database\_host == null because count expressions cannot depend on values computed at apply time. | `bool` | `true` | no |
| <a name="input_create_postgres_kms_key"></a> [create\_postgres\_kms\_key](#input\_create\_postgres\_kms\_key) | When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create\_kms\_key\_ring/existing\_kms\_key\_ring\_id) and configures the module-managed Cloud SQL instance to use it as its customer-managed encryption key. Mutually exclusive with existing\_postgres\_kms\_key\_id. Ignored when create\_postgres\_instance = false. Defaults to false (Google-managed encryption). The created key is protected by lifecycle prevent\_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key. | `bool` | `false` | no |
| <a name="input_create_psa"></a> [create\_psa](#input\_create\_psa) | When true (the default), the module allocates and manages the Private Service Access range and service networking connection used by Cloud SQL and Memorystore. Set to false when the network already has a Private Service Access connection the module should not manage; existing\_psa\_prerequisites\_attestation must then be true if any module-managed data service is created. | `bool` | `true` | no |
| <a name="input_create_redis_instance"></a> [create\_redis\_instance](#input\_create\_redis\_instance) | When true (the default), the module creates and manages a Memorystore for Redis instance. Set to false to use an external Redis-compatible service; redis\_host must then be supplied (redis\_port, redis\_tls\_enabled, redis\_username, and a password source are optional depending on the target service). | `bool` | `true` | no |
| <a name="input_create_redis_kms_key"></a> [create\_redis\_kms\_key](#input\_create\_redis\_kms\_key) | When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create\_kms\_key\_ring/existing\_kms\_key\_ring\_id) and configures the module-managed Memorystore instance to use it as its customer-managed encryption key. Mutually exclusive with existing\_redis\_kms\_key\_id. Ignored when create\_redis\_instance = false. Defaults to false (Google-managed encryption). The created key is protected by lifecycle prevent\_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key. | `bool` | `false` | no |
| <a name="input_db_ping_interval_seconds"></a> [db\_ping\_interval\_seconds](#input\_db\_ping\_interval\_seconds) | Seconds between database health-check pings. Wired to DB\_PING\_INTERVAL\_SECONDS on every n8n role, for both managed Cloud SQL and external PostgreSQL. Null (the default) omits the override so n8n's own default applies. | `number` | `null` | no |
| <a name="input_db_ping_max_failures_before_recovery"></a> [db\_ping\_max\_failures\_before\_recovery](#input\_db\_ping\_max\_failures\_before\_recovery) | Number of consecutive failed database pings n8n tolerates before entering recovery. Wired to DB\_PING\_MAX\_FAILURES\_BEFORE\_RECOVERY on every n8n role, for both managed Cloud SQL and external PostgreSQL. Null (the default) omits the override so n8n's own default applies. | `number` | `null` | no |
| <a name="input_db_ping_timeout_ms"></a> [db\_ping\_timeout\_ms](#input\_db\_ping\_timeout\_ms) | Milliseconds n8n waits for a database ping to respond before considering the connection unhealthy. Wired to DB\_PING\_TIMEOUT\_MS on every n8n role (main, worker, webhook processor), for both managed Cloud SQL and external PostgreSQL. Null (the default) omits the override so n8n's own default applies. | `number` | `null` | no |
| <a name="input_db_postgresdb_connection_timeout_ms"></a> [db\_postgresdb\_connection\_timeout\_ms](#input\_db\_postgresdb\_connection\_timeout\_ms) | Milliseconds n8n waits to acquire a connection slot from db\_postgresdb\_pool\_size before failing the request (TypeORM connection-acquisition timeout, distinct from db\_ping\_timeout\_ms's health-check timeout). Wired to DB\_POSTGRESDB\_CONNECTION\_TIMEOUT on every n8n role, for both managed Cloud SQL and external PostgreSQL. Zero disables this acquisition timeout. Null (the default) omits the override so n8n's own default applies. | `number` | `null` | no |
| <a name="input_db_postgresdb_pool_size"></a> [db\_postgresdb\_pool\_size](#input\_db\_postgresdb\_pool\_size) | Maximum number of TypeORM connection pool slots per n8n pod. Pool connections are acquired lazily on demand, up to this ceiling, not held open continuously from startup; a pod that never reaches this many concurrent queries never opens this many connections. db\_ping\_timeout\_ms/db\_postgresdb\_connection\_timeout\_ms bound how long a request waits to acquire a slot from this pool once it is exhausted. Rule of thumb: pool\_size >= worker\_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20). | `number` | `10` | no |
| <a name="input_db_postgresdb_ssl_enabled"></a> [db\_postgresdb\_ssl\_enabled](#input\_db\_postgresdb\_ssl\_enabled) | Whether n8n connects to the database over SSL. For Cloud SQL over Private Services Access the recommended default is false: the instance uses ssl\_mode ALLOW\_UNENCRYPTED\_AND\_ENCRYPTED and traffic stays on the VPC private network. Set to true to require SSL; certificate verification is skipped (DB\_POSTGRESDB\_SSL\_REJECT\_UNAUTHORIZED=false). | `bool` | `false` | no |
| <a name="input_existing_cloud_armor_policy_name"></a> [existing\_cloud\_armor\_policy\_name](#input\_existing\_cloud\_armor\_policy\_name) | Name of an existing Cloud Armor security policy to attach to the managed ingress's BackendConfig instead of a module-created CIDR allow-list. Mutually exclusive with ingress\_source\_cidrs. Leave null (the default) for no existing policy. Ignored when create\_ingress = false. | `string` | `null` | no |
| <a name="input_existing_gcs_bucket_name"></a> [existing\_gcs\_bucket\_name](#input\_existing\_gcs\_bucket\_name) | Name of the existing GCS bucket used for n8n binary storage. Required when create\_gcs\_bucket = false. Ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_gcs_kms_key_id"></a> [existing\_gcs\_kms\_key\_id](#input\_existing\_gcs\_kms\_key\_id) | Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed GCS bucket should use for customer-managed encryption. Mutually exclusive with create\_gcs\_kms\_key. The module grants no IAM on a supplied existing key; grant the Cloud Storage service agent roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create\_gcs\_bucket = false. | `string` | `null` | no |
| <a name="input_existing_gke_cluster_name"></a> [existing\_gke\_cluster\_name](#input\_existing\_gke\_cluster\_name) | Name of the existing regional GKE cluster (in gcp\_region) to deploy n8n onto. Required when create\_gke = false. Ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_gke_prerequisites_attestation"></a> [existing\_gke\_prerequisites\_attestation](#input\_existing\_gke\_prerequisites\_attestation) | Explicit attestation that the existing GKE cluster named by existing\_gke\_cluster\_name is reachable by the configured providers, uses VPC-native networking, has Workload Identity enabled, runs GKE's native ingress/metrics/autoscaling/PD CSI controllers, has capacity for the requested n8n workload, and grants this module permission to create namespaced resources. The module cannot safely audit these properties; it trusts this attestation. Required (must be true) when create\_gke = false. | `bool` | `false` | no |
| <a name="input_existing_gke_workload_identity_pool"></a> [existing\_gke\_workload\_identity\_pool](#input\_existing\_gke\_workload\_identity\_pool) | Workload Identity pool of the existing GKE cluster (normally <project\_id>.svc.id.goog). Only needed when the existing cluster's Workload Identity pool belongs to a different Google Cloud project than project\_id (a cross-project binding). Ignored when create\_gke = true. Leave null to use <project\_id>.svc.id.goog. | `string` | `null` | no |
| <a name="input_existing_keda_prerequisites_attestation"></a> [existing\_keda\_prerequisites\_attestation](#input\_existing\_keda\_prerequisites\_attestation) | Explicit attestation that a compatible KEDA operator and CRDs are already installed and running on the cluster. The module cannot safely audit this; it trusts this attestation. Required (must be true) when install\_keda = false and n8n\_worker\_keda\_enabled = true. Ignored otherwise. | `bool` | `false` | no |
| <a name="input_existing_kms_key_ring_id"></a> [existing\_kms\_key\_ring\_id](#input\_existing\_kms\_key\_ring\_id) | Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>) of an existing Cloud KMS key ring to host module-created CMEK keys. Required when create\_kms\_key\_ring = false and at least one service's create\_*\_kms\_key switch is true. Ignored when create\_kms\_key\_ring = true or no module-created key is requested. | `string` | `null` | no |
| <a name="input_existing_n8n_core_secret_name"></a> [existing\_n8n\_core\_secret\_name](#input\_existing\_n8n\_core\_secret\_name) | Name of an existing Kubernetes Secret (in n8n\_kube\_namespace) holding N8N\_ENCRYPTION\_KEY, N8N\_HOST, N8N\_PORT, and N8N\_PROTOCOL - the n8n Helm chart's secretRefs.existingSecret core-Secret contract. When set, the module creates no core Secret and generates no encryption key; n8n\_license\_key\_secret\_ref must then be set, because the chart's core-Secret contract requires the license to come from a separate Secret, not n8n\_license\_key. Leave null (the default) for the module to generate the encryption key and create the core Secret itself. | `string` | `null` | no |
| <a name="input_existing_network_name"></a> [existing\_network\_name](#input\_existing\_network\_name) | Name of the existing VPC network to use. Required when create\_network = false. Ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_network_project_id"></a> [existing\_network\_project\_id](#input\_existing\_network\_project\_id) | Host project ID of the existing network, when it lives in a Shared VPC host project different from project\_id. Ignored when create\_network = true. Defaults to project\_id (the network lives in the same project) when left null. | `string` | `null` | no |
| <a name="input_existing_pods_range_name"></a> [existing\_pods\_range\_name](#input\_existing\_pods\_range\_name) | Name of the existing secondary IP range on existing\_subnetwork\_name used for GKE pod alias IPs. Required when create\_network = false. Ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_postgres_kms_key_id"></a> [existing\_postgres\_kms\_key\_id](#input\_existing\_postgres\_kms\_key\_id) | Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed Cloud SQL instance should use for customer-managed encryption. Mutually exclusive with create\_postgres\_kms\_key. The module grants no IAM on a supplied existing key; grant the Cloud SQL service agent roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create\_postgres\_instance = false. | `string` | `null` | no |
| <a name="input_existing_psa_prerequisites_attestation"></a> [existing\_psa\_prerequisites\_attestation](#input\_existing\_psa\_prerequisites\_attestation) | Explicit attestation that an existing Private Service Access allocation and service networking connection already exist on the target network and are compatible with a module-managed Cloud SQL or Memorystore instance. Required (must be true) when create\_psa = false and either create\_postgres\_instance or create\_redis\_instance is true. The module does not read or verify the existing connection; it only trusts this attestation and never mutates or deletes it. | `bool` | `false` | no |
| <a name="input_existing_redis_kms_key_id"></a> [existing\_redis\_kms\_key\_id](#input\_existing\_redis\_kms\_key\_id) | Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed Memorystore instance should use for customer-managed encryption. Mutually exclusive with create\_redis\_kms\_key. The module grants no IAM on a supplied existing key; grant the Memorystore service agent roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create\_redis\_instance = false. | `string` | `null` | no |
| <a name="input_existing_services_range_name"></a> [existing\_services\_range\_name](#input\_existing\_services\_range\_name) | Name of the existing secondary IP range on existing\_subnetwork\_name used for GKE service alias IPs. Required when create\_network = false. Ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_subnetwork_name"></a> [existing\_subnetwork\_name](#input\_existing\_subnetwork\_name) | Name of the existing subnetwork (in gcp\_region) that GKE and data services attach to. Required when create\_network = false. Ignored otherwise. | `string` | `null` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module creates (e.g. <friendly\_name\_prefix>-n8n for the GKE cluster, <friendly\_name\_prefix>-n8n-pg for Cloud SQL). Most commonly an environment (e.g. "sandbox", "prod"), team, or project name. | `string` | n/a | yes |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region for regional resources (GKE, Cloud SQL, Memorystore, subnet). | `string` | `"europe-west1"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete a non-empty bucket (dev only). | `bool` | `false` | no |
| <a name="input_gcs_hmac_access_id"></a> [gcs\_hmac\_access\_id](#input\_gcs\_hmac\_access\_id) | BYO HMAC mode: the HMAC access ID (S3 access key) for the pre-existing key. Required when gcs\_hmac\_service\_account\_email is set. | `string` | `""` | no |
| <a name="input_gcs_hmac_secret"></a> [gcs\_hmac\_secret](#input\_gcs\_hmac\_secret) | BYO HMAC mode: the HMAC secret (S3 secret access key). The module wraps it in the n8n-s3-secret Kubernetes Secret. Ignored if gcs\_hmac\_secret\_name is set. Prefer gcs\_hmac\_secret\_name to keep the raw secret out of Terraform state. | `string` | `""` | no |
| <a name="input_gcs_hmac_secret_name"></a> [gcs\_hmac\_secret\_name](#input\_gcs\_hmac\_secret\_name) | BYO HMAC mode (most locked-down): name of an EXISTING Kubernetes Secret in the n8n namespace holding the HMAC secret under key 'accessSecret'. When set, the module references it directly and creates no Secret, so the raw secret never enters Terraform state. Overrides gcs\_hmac\_secret. | `string` | `""` | no |
| <a name="input_gcs_hmac_service_account_email"></a> [gcs\_hmac\_service\_account\_email](#input\_gcs\_hmac\_service\_account\_email) | BYO HMAC mode: email of a PRE-EXISTING service account that owns an<br/>out-of-band-created HMAC key. When set, the module does NOT create the storage<br/>service account or the HMAC key; it grants this SA objectAdmin on the bucket<br/>and wires the credentials below into n8n. Requires gcs\_hmac\_access\_id and<br/>either gcs\_hmac\_secret or gcs\_hmac\_secret\_name. Empty = default (module<br/>creates the key). | `string` | `""` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location (region or multi-region). | `string` | `"EU"` | no |
| <a name="input_gke_control_plane_authorized_networks"></a> [gke\_control\_plane\_authorized\_networks](#input\_gke\_control\_plane\_authorized\_networks) | CIDRs allowed to reach the control-plane endpoint. Empty = open (dev only); set to your admin CIDRs for a locked-down control plane. | <pre>list(object({<br/>    cidr_block   = string<br/>    display_name = string<br/>  }))</pre> | `[]` | no |
| <a name="input_gke_control_plane_cidr"></a> [gke\_control\_plane\_cidr](#input\_gke\_control\_plane\_cidr) | CIDR for the GKE control-plane peering range (private cluster). Must not overlap the subnet/pods/services ranges. | `string` | `"172.16.0.0/28"` | no |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster (google provider default is true). | `bool` | `true` | no |
| <a name="input_gke_enable_private_nodes"></a> [gke\_enable\_private\_nodes](#input\_gke\_enable\_private\_nodes) | Give nodes private IPs only (egress via Cloud NAT). Control-plane endpoint stays public unless locked down via gke\_control\_plane\_authorized\_networks. | `bool` | `true` | no |
| <a name="input_gke_min_master_version"></a> [gke\_min\_master\_version](#input\_gke\_min\_master\_version) | Optional control-plane version prefix (e.g. "1.32"). Empty lets the release channel decide. | `string` | `""` | no |
| <a name="input_gke_node_disk_size_gb"></a> [gke\_node\_disk\_size\_gb](#input\_gke\_node\_disk\_size\_gb) | Node boot disk size in GB. | `number` | `100` | no |
| <a name="input_gke_node_disk_type"></a> [gke\_node\_disk\_type](#input\_gke\_node\_disk\_type) | Node boot disk type (pd-standard, pd-balanced, pd-ssd). | `string` | `"pd-balanced"` | no |
| <a name="input_gke_node_max_per_zone"></a> [gke\_node\_max\_per\_zone](#input\_gke\_node\_max\_per\_zone) | Autoscaling maximum nodes PER ZONE (total max is roughly this x number of zones). | `number` | `2` | no |
| <a name="input_gke_node_min_per_zone"></a> [gke\_node\_min\_per\_zone](#input\_gke\_node\_min\_per\_zone) | Autoscaling minimum nodes PER ZONE. A regional cluster spans ~3 zones, so total min is roughly this x3. | `number` | `1` | no |
| <a name="input_gke_node_type"></a> [gke\_node\_type](#input\_gke\_node\_type) | Node machine type. | `string` | `"e2-standard-4"` | no |
| <a name="input_gke_release_channel"></a> [gke\_release\_channel](#input\_gke\_release\_channel) | GKE release channel: RAPID, REGULAR, STABLE, or UNSPECIFIED (to pin a version). | `string` | `"REGULAR"` | no |
| <a name="input_https_redirect"></a> [https\_redirect](#input\_https\_redirect) | Redirect HTTP->HTTPS at the LB via a FrontendConfig. Set false while a google\_managed cert is still provisioning (Google needs HTTP reachable), then flip true. | `bool` | `true` | no |
| <a name="input_ingress_source_cidrs"></a> [ingress\_source\_cidrs](#input\_ingress\_source\_cidrs) | CIDR blocks allowed to reach n8n through the managed ingress. When non-empty, the module creates a Cloud Armor security policy (google\_compute\_security\_policy.n8n) that allows only these CIDRs and denies every other source, attached to the ingress via BackendConfig.spec.securityPolicy (crds.tf). Every webhook sender must be included in this list, or their requests will be denied. Mutually exclusive with existing\_cloud\_armor\_policy\_name. Leave empty (the default) for no source restriction. Ignored when create\_ingress = false. | `list(string)` | `[]` | no |
| <a name="input_ingress_ssl_policy_name"></a> [ingress\_ssl\_policy\_name](#input\_ingress\_ssl\_policy\_name) | Name of an existing Google Cloud SSL policy the managed ingress's target HTTPS proxy should use, e.g. to enforce TLS 1.2+ or a restricted cipher profile. Attached via the FrontendConfig CR's sslPolicy field (crds.tf). Leave null (the default) for GKE's default SSL policy. Ignored when create\_ingress = false. | `string` | `null` | no |
| <a name="input_install_keda"></a> [install\_keda](#input\_install\_keda) | When true (the default), the module installs and manages the KEDA Helm release via modules/controllers before creating n8n worker ScaledObjects. Set to false to use an existing KEDA installation; existing\_keda\_prerequisites\_attestation must then be true whenever n8n\_worker\_keda\_enabled = true. | `bool` | `true` | no |
| <a name="input_keda_chart_repository"></a> [keda\_chart\_repository](#input\_keda\_chart\_repository) | Helm chart repository KEDA is installed from (modules/controllers). Accepts an HTTPS chart-repository URL or an OCI registry reference (oci://...), so a private mirror can replace the public kedacore charts. Ignored when install\_keda = false. | `string` | `"https://kedacore.github.io/charts"` | no |
| <a name="input_keda_chart_version"></a> [keda\_chart\_version](#input\_keda\_chart\_version) | KEDA Helm chart version to deploy (kedacore/charts). Pinned so every apply installs the same operator version; bump deliberately and re-run the test suite rather than floating to latest. Must be an exact semantic version. Passed through to modules/controllers. Ignored when install\_keda = false. | `string` | `"2.20.1"` | no |
| <a name="input_kms_key_ring_location"></a> [kms\_key\_ring\_location](#input\_kms\_key\_ring\_location) | Location for the module-managed Cloud KMS key ring. Defaults to gcp\_region for Cloud SQL/Redis keys, or to the GCS-compatible bucket location for a GCS-only ring (EU maps to europe). Every service sharing the ring must support the same location. | `string` | `null` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let this module set a PROJECT-LEVEL override that turns OFF the<br/>iam.disableServiceAccountKeyCreation org policy, so the GCS HMAC key can be<br/>created. Default false, the module does not touch org policy.<br/>Set true ONLY IF: (a) your credentials have roles/orgpolicy.policyAdmin (org/<br/>folder-level; a normal project deployer does not), and (b) your org permits<br/>overriding this guardrail. Otherwise disable the policy out-of-band and leave<br/>this false. Requires the orgpolicy.googleapis.com API enabled. | `bool` | `false` | no |
| <a name="input_n8n_chart_repository"></a> [n8n\_chart\_repository](#input\_n8n\_chart\_repository) | Helm chart repository the n8n chart is installed from. Accepts an HTTPS chart-repository URL or an OCI registry reference (oci://...), so a private mirror can replace the public upstream (oci://ghcr.io/n8n-io/n8n-helm-chart) for a cluster with no egress to it. The mirror must serve the exact version named by n8n\_chart\_version; this module does not verify that a mirrored repository actually carries it. | `string` | `"oci://ghcr.io/n8n-io/n8n-helm-chart"` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | n8n Helm chart version to deploy (n8n-io/n8n-hosting charts/n8n). Must be an exact semantic version (e.g. "1.10.1"), not a range or floating tag, so every apply is deterministic. | `string` | `"1.10.1"` | no |
| <a name="input_n8n_community_packages_prevent_loading"></a> [n8n\_community\_packages\_prevent\_loading](#input\_n8n\_community\_packages\_prevent\_loading) | Prevent installed community packages from being loaded at runtime. Maps to N8N\_COMMUNITY\_PACKAGES\_PREVENT\_LOADING. When true, n8n leaves the community-packages management surface in place but skips loading the package code, which is useful for locking an instance down without uninstalling. Leave false (the default) for community nodes to load and execute. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. | `bool` | `false` | no |
| <a name="input_n8n_community_packages_registry"></a> [n8n\_community\_packages\_registry](#input\_n8n\_community\_packages\_registry) | HTTPS URL of a custom registry n8n uses to resolve community (npm) package installs, mapped to N8N\_COMMUNITY\_PACKAGES\_REGISTRY on every n8n role (main, worker, webhook processor). Null (the default) leaves n8n's own npm registry default in place. Must not embed credentials (no user:pass@ userinfo); authenticate the registry itself (e.g. a network-level allowlist or a registry that accepts anonymous reads from the cluster's egress path), since this module has no separate mechanism for registry credentials. Community package installation itself is a distinct Enterprise entitlement from this registry override; setting this value does not enable or unlock community packages by itself. | `string` | `null` | no |
| <a name="input_n8n_compression_max_decompressed_size_bytes"></a> [n8n\_compression\_max\_decompressed\_size\_bytes](#input\_n8n\_compression\_max\_decompressed\_size\_bytes) | Maximum total decompressed size, in bytes, n8n allows when decompressing an archive (e.g. inside the Compression node), mapped to N8N\_COMPRESSION\_NODE\_MAX\_DECOMPRESSED\_SIZE\_BYTES on every n8n role. Null (the default) leaves n8n's own upstream limit in place, so a future n8n release can change that default without this module pinning it. | `number` | `null` | no |
| <a name="input_n8n_compression_max_zip_entries"></a> [n8n\_compression\_max\_zip\_entries](#input\_n8n\_compression\_max\_zip\_entries) | Maximum number of entries n8n allows when decompressing a zip archive (e.g. inside the Compression node), mapped to N8N\_COMPRESSION\_NODE\_MAX\_ZIP\_ENTRIES on every n8n role. Null (the default) leaves n8n's own upstream limit in place, so a future n8n release can change that default without this module pinning it. | `number` | `null` | no |
| <a name="input_n8n_credentials_overwrite_secret_ref"></a> [n8n\_credentials\_overwrite\_secret\_ref](#input\_n8n\_credentials\_overwrite\_secret\_ref) | Reference to an existing Kubernetes Secret (in the n8n namespace) holding a credential-overwrites JSON payload, mounted read-only at /etc/n8n/credentials-overwrite/overwrites.json on every n8n role with CREDENTIALS\_OVERWRITE\_DATA\_FILE pointed at it. The module never reads, hashes, or copies the referenced Secret's contents into Terraform state, Helm values, or another Secret; a missing Secret or key fails at pod-start time, not at plan time. Changing only the Secret's contents does not trigger an automatic rollout: restart n8n-main, n8n-worker, and n8n-webhook-processor deployments to pick up new data. Leave null (the default) to leave credential overwrites unconfigured, in which case CREDENTIALS\_OVERWRITE\_DATA/CREDENTIALS\_OVERWRITE\_DATA\_FILE remain available through n8n\_extra\_env as before. | <pre>object({<br/>    name = string<br/>    key  = string<br/>  })</pre> | `null` | no |
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on every pod type (main, worker, webhook processor). This is the supported way to ship nodes baked into a custom image: since n8n 1.0 the loader no longer picks up nodes from the image's global node\_modules, so a plain npm install into the image is never seen. Something has to put files at this path, so pair this with n8n\_image\_repository pointing at an image that bakes them in. The path must be outside /home/node/.n8n, which the chart mounts over on main pods. Nodes loaded this way are registered under the package name CUSTOM, so a node whose type was n8n-nodes-example.myNode when installed from npm becomes CUSTOM.myNode, and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var entirely. | `string` | `null` | no |
| <a name="input_n8n_database_host"></a> [n8n\_database\_host](#input\_n8n\_database\_host) | External database host. Required when create\_postgres\_instance = false. Ignored otherwise. Use this to pass any external PostgreSQL host. | `string` | `null` | no |
| <a name="input_n8n_database_name"></a> [n8n\_database\_name](#input\_n8n\_database\_name) | n8n database name. | `string` | `"n8n_enterprise"` | no |
| <a name="input_n8n_database_password"></a> [n8n\_database\_password](#input\_n8n\_database\_password) | Direct password for the external database specified by n8n\_database\_host. Exactly one of n8n\_database\_password or n8n\_database\_password\_secret\_ref is required when create\_postgres\_instance = false. Ignored otherwise (the module generates a random password for its managed Cloud SQL instance). | `string` | `null` | no |
| <a name="input_n8n_database_password_secret_ref"></a> [n8n\_database\_password\_secret\_ref](#input\_n8n\_database\_password\_secret\_ref) | Reference to an existing Kubernetes Secret (in the n8n namespace) holding the external database password, instead of passing the value directly through n8n\_database\_password. key defaults to "password" when omitted. The module never reads the referenced Secret's value; it only passes the reference through to the n8n Helm chart's database.passwordSecret. Exactly one of n8n\_database\_password or n8n\_database\_password\_secret\_ref is required when create\_postgres\_instance = false. Ignored otherwise. | <pre>object({<br/>    name = string<br/>    key  = optional(string, "password")<br/>  })</pre> | `null` | no |
| <a name="input_n8n_database_user"></a> [n8n\_database\_user](#input\_n8n\_database\_user) | n8n database user. | `string` | `"n8n"` | no |
| <a name="input_n8n_dns_config"></a> [n8n\_dns\_config](#input\_n8n\_dns\_config) | Pod-level DNS settings applied to the main, worker, and webhook-processor<br/>pods (the chart's top-level `dnsConfig`, rendered into all three pod<br/>specs). Defaults to null, which omits the block entirely and leaves<br/>Kubernetes' cluster DNS policy and resolver defaults unchanged, so this is<br/>a no-op unless set.<br/><br/>Nameservers are validated as plain IPv4 or IPv6 addresses, at most 3,<br/>matching the limits the Kubernetes pod spec enforces at admission.<br/><br/>Search domains are validated against strict RFC 1123 subdomain rules:<br/>lowercase alphanumeric labels and hyphens only, no underscores, and no<br/>bare "." or trailing dot. This module targets GKE's supported release<br/>channels (REGULAR/STABLE), whose control planes can run versions as old<br/>as those still receiving upstream support; Kubernetes' relaxed search-path<br/>validation (RelaxedDNSSearchValidation) only reached GA in 1.34, so an<br/>older but still-supported cluster validates search domains strictly at<br/>admission and rejects the relaxed shapes (bare ".", underscores) even<br/>though a newer cluster would accept them. This variable validates to the<br/>stricter grammar every supported GKE release admits, rather than silently<br/>depending on the newer gate.<br/><br/>At most 32 search entries totalling 2048 characters (joined by single<br/>spaces), matching the Kubernetes API server's own admission limit.<br/><br/>DNS options must have unique names: the API server admits only one value<br/>per name, so a duplicate silently drops one entry rather than merging or<br/>erroring. The ndots option, if present, must carry a whole number from 0<br/>to 15 written as a string. | <pre>object({<br/>    nameservers = optional(list(string))<br/>    searches    = optional(list(string))<br/>    options = optional(list(object({<br/>      name  = string<br/>      value = optional(string)<br/>    })))<br/>  })</pre> | `null` | no |
| <a name="input_n8n_encryption_key"></a> [n8n\_encryption\_key](#input\_n8n\_encryption\_key) | Direct n8n encryption key to reuse instead of letting the module generate one, e.g. when restoring/cloning a database whose existing credentials were encrypted with a known key. Exactly 64 hexadecimal characters, matching the module's own generated-key format (32 random bytes, hex-encoded). Mutually exclusive with existing\_n8n\_core\_secret\_name, which supplies the encryption key through an entire caller-managed core Secret instead. Leave null (the default) for the module to generate one, whose value is exposed by the n8n\_encryption\_key output. This reuses a key; it does not rotate one or prove the key matches a given database. | `string` | `null` | no |
| <a name="input_n8n_execution_concurrency_limit"></a> [n8n\_execution\_concurrency\_limit](#input\_n8n\_execution\_concurrency\_limit) | Maximum concurrent production executions (-1 to disable) | `number` | `100` | no |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Maps to N8N\_EXECUTION\_DATA\_STORAGE\_MODE. "database" (the default) keeps execution data in PostgreSQL, matching n8n's own default, and emits no env var. "s3" offloads it to the effective GCS S3-compatible storage contract this module already configures for binary data (the same bucket, HMAC identity, and Secret), so no extra bucket or credentials are needed. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, a different entitlement from the one binary data offload uses. There is no backfill: only new executions go to object storage. "filesystem" is not accepted: pod filesystems are ephemeral and unshared in this module's queue-mode topology. | `string` | `"database"` | no |
| <a name="input_n8n_execution_timeout"></a> [n8n\_execution\_timeout](#input\_n8n\_execution\_timeout) | Default execution timeout in seconds (-1 to disable) | `number` | `7200` | no |
| <a name="input_n8n_execution_timeout_max"></a> [n8n\_execution\_timeout\_max](#input\_n8n\_execution\_timeout\_max) | Maximum execution timeout users can configure in seconds | `number` | `7200` | no |
| <a name="input_n8n_executions_data_save_manual_executions"></a> [n8n\_executions\_data\_save\_manual\_executions](#input\_n8n\_executions\_data\_save\_manual\_executions) | Whether to save data for executions triggered manually from the editor (the chart's executions.data.saveManualExecutions / EXECUTIONS\_DATA\_SAVE\_MANUAL\_EXECUTIONS). Defaults to true, matching n8n's own default. | `bool` | `true` | no |
| <a name="input_n8n_executions_data_save_on_error"></a> [n8n\_executions\_data\_save\_on\_error](#input\_n8n\_executions\_data\_save\_on\_error) | Whether to save data for failed execution runs (the chart's executions.data.saveOnError / EXECUTIONS\_DATA\_SAVE\_ON\_ERROR). "all" (the default, and n8n's own default) saves every failed execution; "none" saves none. | `string` | `"all"` | no |
| <a name="input_n8n_executions_data_save_on_progress"></a> [n8n\_executions\_data\_save\_on\_progress](#input\_n8n\_executions\_data\_save\_on\_progress) | Whether to save in-progress execution data as each node completes, so a still-running or crashed execution's partial state is visible (the chart's executions.data.saveOnProgress / EXECUTIONS\_DATA\_SAVE\_ON\_PROGRESS). Defaults to false, matching n8n's own default; enabling it increases database writes per execution. | `bool` | `false` | no |
| <a name="input_n8n_executions_data_save_on_success"></a> [n8n\_executions\_data\_save\_on\_success](#input\_n8n\_executions\_data\_save\_on\_success) | Whether to save data for successful execution runs (the chart's executions.data.saveOnSuccess / EXECUTIONS\_DATA\_SAVE\_ON\_SUCCESS). "all" (the default, and n8n's own default) saves every successful execution; "none" saves none. | `string` | `"all"` | no |
| <a name="input_n8n_external_secrets_enabled"></a> [n8n\_external\_secrets\_enabled](#input\_n8n\_external\_secrets\_enabled) | Master switch for n8n's External Secrets feature (vault-provider connections configured in Settings > External Secrets). When true (the default, matching n8n's own default), the feature is available. When false, the module adds "external-secrets" to N8N\_DISABLED\_MODULES on every n8n pod, disabling the feature entirely. | `bool` | `true` | no |
| <a name="input_n8n_external_secrets_update_interval"></a> [n8n\_external\_secrets\_update\_interval](#input\_n8n\_external\_secrets\_update\_interval) | Seconds between checks for updates to resolved external secret values. Maps to N8N\_EXTERNAL\_SECRETS\_UPDATE\_INTERVAL. Leave null (the default) to use n8n's own default (300s). Ignored when n8n\_external\_secrets\_enabled = false. | `number` | `null` | no |
| <a name="input_n8n_extra_env"></a> [n8n\_extra\_env](#input\_n8n\_extra\_env) | Additional environment variables to inject into all n8n pods (main, worker, and webhook-processor) via the Helm chart's config.extraEnv list. Each entry is an object with name and value string attributes. config.extraEnv is appended last in every container's env list, so by Kubernetes' last-wins rule any name here overrides the chart's value for that name. To prevent silently breaking the deployment, an entry is rejected at plan time when its name collides with a connection, identity, storage, license, or topology variable the module manages: any name starting with DB\_, QUEUE\_, N8N\_RUNNERS\_, N8N\_EXTERNAL\_STORAGE\_S3\_, N8N\_MULTI\_MAIN\_, or AWS\_, plus names like N8N\_ENCRYPTION\_KEY, N8N\_LICENSE\_ACTIVATION\_KEY, N8N\_HOST, WEBHOOK\_URL, and EXECUTIONS\_MODE. Use the dedicated module inputs for those. Do not put secret values here, because they render into the Helm release and are stored in plaintext in Terraform state; instead pass a *\_FILE companion (e.g. a name ending in \_FILE) pointing at a mounted Kubernetes secret, or use n8n credentials. Example: [{name = "N8N\_DEFAULT\_LOCALE", value = "de"}]. | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_extra_volume_mounts"></a> [n8n\_extra\_volume\_mounts](#input\_n8n\_extra\_volume\_mounts) | Mounts of n8n\_extra\_volumes entries into every n8n pod (main, worker, webhook processor) via the chart's extraVolumeMounts. Each entry's name must match a declared n8n\_extra\_volumes entry. mount\_path must be an absolute, canonical container path outside the module's own protected mounts (/home/node/.n8n, the main pod's data directory; /etc/n8n-certs, the managed Redis CA mount). read\_only defaults to true; set false only for a PVC the caller's workload actually needs to write to. | <pre>list(object({<br/>    name       = string<br/>    mount_path = string<br/>    sub_path   = optional(string, null)<br/>    read_only  = optional(bool, true)<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_extra_volumes"></a> [n8n\_extra\_volumes](#input\_n8n\_extra\_volumes) | Existing ConfigMaps, Secrets, or PVCs to mount into every n8n pod (main, worker, webhook processor) via the chart's extraVolumes. Each entry has a name and exactly one typed source: config\_map, secret, or persistent\_volume\_claim. The module creates and reads none of the referenced objects; provisioning and lifecycle stay the caller's responsibility. A PVC mounted read-write on more than one pod needs a caller-provisioned ReadWriteMany-capable StorageClass, since n8n runs multiple replicas of every role. Pair entries here with n8n\_extra\_volume\_mounts to actually mount them somewhere; declaring a volume with no matching mount has no effect. Reserved volume names data, task-runner-config, and redis-ca belong to the chart/module and cannot be reused. | <pre>list(object({<br/>    name = string<br/>    config_map = optional(object({<br/>      name = string<br/>      items = optional(list(object({<br/>        key  = string<br/>        path = string<br/>      })), null)<br/>      default_mode = optional(string, null)<br/>    }), null)<br/>    secret = optional(object({<br/>      name = string<br/>      items = optional(list(object({<br/>        key  = string<br/>        path = string<br/>      })), null)<br/>      default_mode = optional(string, null)<br/>    }), null)<br/>    persistent_volume_claim = optional(object({<br/>      claim_name = string<br/>    }), null)<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Fully-qualified domain name for n8n (e.g. n8n.example.com). Must match the certificate served for the chosen tls\_mode. | `string` | n/a | yes |
| <a name="input_n8n_helm_timeout"></a> [n8n\_helm\_timeout](#input\_n8n\_helm\_timeout) | Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s. | `number` | `600` | no |
| <a name="input_n8n_image_pull_policy"></a> [n8n\_image\_pull\_policy](#input\_n8n\_image\_pull\_policy) | Image pull policy for the n8n application image. Maps to the chart's image.pullPolicy. Leave null (the default) to use the chart's own default (IfNotPresent). One of Always, IfNotPresent, or Never. | `string` | `null` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes Secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node pool's default credentials cannot already reach: a public registry and Artifact Registry/Container Registry in this project both pull without credentials. Setting this moves ownership of the n8n Kubernetes ServiceAccount from the Helm chart to the module (the pinned chart renders imagePullSecrets nowhere, on the pod spec or on the ServiceAccount, so attaching the secrets to the account the pods already run as is the only way in), and the module keeps the Workload Identity annotation on the account it creates instead. Create and rotate the Secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "us-docker.pkg.dev/<project>/<repo>/n8n"). When it is null (the default), the Helm chart's own repository applies (currently docker.n8n.io/n8nio/n8n). Point this at a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable: a public registry needs nothing extra, GKE nodes can already pull from Artifact Registry and Container Registry in the same project without credentials, and any other private registry needs its credentials listed in n8n\_image\_pull\_secrets. Set the tag through n8n\_image\_tag, not here, and set n8n\_task\_runner\_image\_tag alongside it whenever the tag is not itself a published n8n version. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). When it is null (the default), the Helm chart's own default applies, currently the floating `stable` tag, which resolves to whatever n8n version is latest at the time each pod starts. Pin this to a concrete version for reproducible, incremental upgrades and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on an unplanned pod reschedule. See https://docs.n8n.io/2-0-breaking-changes/ for the n8n 2.x migration guide. | `string` | `null` | no |
| <a name="input_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#input\_n8n\_kube\_namespace) | Kubernetes namespace to deploy n8n into. Also names the existing namespace when create\_namespace = false. | `string` | `"n8n"` | no |
| <a name="input_n8n_kube_svc_account"></a> [n8n\_kube\_svc\_account](#input\_n8n\_kube\_svc\_account) | Kubernetes ServiceAccount the n8n pods run as (annotated for Workload Identity). Matches the n8n Helm chart's serviceAccount name. | `string` | `"n8n"` | no |
| <a name="input_n8n_license_detach_floating_on_shutdown"></a> [n8n\_license\_detach\_floating\_on\_shutdown](#input\_n8n\_license\_detach\_floating\_on\_shutdown) | Whether n8n main pods detach their floating license entitlement on shutdown. Maps to N8N\_LICENSE\_DETACH\_FLOATING\_ON\_SHUTDOWN. n8n's upstream default is true, which is safe for a single main but breaks multi-main (the module default, two main replicas): the leader main detaches on shutdown and zeroes the shared floating cert in the database, so any fresh main pod that starts as a follower reads the zeroed cert, fails the init-time license gate, and crash-loops, which can push a Helm release with atomic = true into a stuck pending-rollback state. The module defaults this to false, overriding n8n's own default, because all mains share the same device fingerprint: a single floating seat is reused across restarts and nothing leaks. Set to true only to restore n8n's upstream behavior, and only for single-main deployments. | `bool` | `false` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Exactly one of n8n\_license\_key or n8n\_license\_key\_secret\_ref is required. | `string` | `null` | no |
| <a name="input_n8n_license_key_secret_ref"></a> [n8n\_license\_key\_secret\_ref](#input\_n8n\_license\_key\_secret\_ref) | Reference to an existing Kubernetes Secret (in the n8n namespace) holding the n8n Enterprise license activation key, instead of passing the value directly through n8n\_license\_key. key defaults to "license-key" when omitted. The module never reads the referenced Secret's value; it only passes the reference through to the n8n Helm chart's license.existingSecret. Exactly one of n8n\_license\_key or n8n\_license\_key\_secret\_ref is required. Also required (instead of n8n\_license\_key) when existing\_n8n\_core\_secret\_name is set, per the chart's core-Secret contract (see existing\_n8n\_core\_secret\_name). | <pre>object({<br/>    name = string<br/>    key  = optional(string, "license-key")<br/>  })</pre> | `null` | no |
| <a name="input_n8n_log_level"></a> [n8n\_log\_level](#input\_n8n\_log\_level) | n8n log level. Maps to the N8N\_LOG\_LEVEL environment variable. One of: silent, error, warn, info, debug, verbose. | `string` | `"info"` | no |
| <a name="input_n8n_log_output"></a> [n8n\_log\_output](#input\_n8n\_log\_output) | n8n log output destination(s). Maps to the N8N\_LOG\_OUTPUT environment variable. Comma-separated subset of: console, file (e.g. "console", "file", "console,file"). Note: this variable does NOT control log *format*, setting an invalid value (e.g. "json") leaves Winston with no transport and silently drops all logs. To emit JSON-formatted logs, configure n8n's logging block separately; this env var only selects destinations. | `string` | `"console"` | no |
| <a name="input_n8n_log_streaming_destinations"></a> [n8n\_log\_streaming\_destinations](#input\_n8n\_log\_streaming\_destinations) | List of log streaming destination objects, JSON-encoded into N8N\_LOG\_STREAMING\_DESTINATIONS. Each entry must set type to webhook, syslog, or sentry, plus the type-specific fields documented at https://docs.n8n.io/log-streaming/#configure-using-environment-variables (common fields: label, enabled, subscribedEvents, anonymizeAuditMessages, circuitBreaker). Typed as any because the three destination shapes differ structurally. Marked sensitive because webhook headers and Sentry DSNs typically carry credentials, note the value is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). Ignored when n8n\_log\_streaming\_managed\_by\_env = false. | `any` | `[]` | no |
| <a name="input_n8n_log_streaming_managed_by_env"></a> [n8n\_log\_streaming\_managed\_by\_env](#input\_n8n\_log\_streaming\_managed\_by\_env) | Manage n8n's Enterprise log streaming destinations from environment variables instead of the UI. Maps to N8N\_LOG\_STREAMING\_MANAGED\_BY\_ENV. When true, n8n applies n8n\_log\_streaming\_destinations on every startup and locks the Log Streaming UI controls read-only. When false (the default), no log streaming env vars are emitted and destinations stay UI-managed; flipping back to false keeps the last applied destinations but restores UI write access. Requires n8n >= 2.19.0 and an Enterprise license that includes log streaming. See https://docs.n8n.io/log-streaming/ for the underlying n8n contract. | `bool` | `false` | no |
| <a name="input_n8n_main_cpu_limit"></a> [n8n\_main\_cpu\_limit](#input\_n8n\_main\_cpu\_limit) | CPU limit for n8n main pods (e.g. 2000m, 1000m) | `string` | `"2000m"` | no |
| <a name="input_n8n_main_cpu_request"></a> [n8n\_main\_cpu\_request](#input\_n8n\_main\_cpu\_request) | CPU request for n8n main pods (e.g. 1000m, 500m) | `string` | `"1000m"` | no |
| <a name="input_n8n_main_fixed_replicas"></a> [n8n\_main\_fixed\_replicas](#input\_n8n\_main\_fixed\_replicas) | Fixed replica count for n8n main pods when n8n\_main\_hpa\_enabled = false. Ignored while the HPA is enabled. A value of 1 selects single-main topology; see n8n\_main\_hpa\_enabled for the licensing and maintenance implications. | `number` | `2` | no |
| <a name="input_n8n_main_hpa_cpu_threshold"></a> [n8n\_main\_hpa\_cpu\_threshold](#input\_n8n\_main\_hpa\_cpu\_threshold) | Target average CPU utilization (%) that triggers scaling of n8n main pods. | `number` | `60` | no |
| <a name="input_n8n_main_hpa_enabled"></a> [n8n\_main\_hpa\_enabled](#input\_n8n\_main\_hpa\_enabled) | When true (the default), the module creates and manages the HPA for n8n main pods. Set to false to let the caller own main-pod scaling (or run a fixed replica count); no n8n main HPA is rendered. n8n\_main\_fixed\_replicas sets the replica count while disabled. Topology follows the selected count either way: n8n\_main\_hpa\_min\_replicas=1 (with this enabled) or n8n\_main\_fixed\_replicas=1 (with this disabled) selects single-main; any larger selected count keeps the module's multi-main default. Single-main requires an n8n Enterprise license edition that supports it (not community edition) and interrupts the editor, REST API, and scheduled triggers during maintenance; it does not by itself grant External Secrets, log streaming, the custom package registry, or object-storage entitlements, and Recreate does not guarantee at-most-one execution after a manual pod deletion, node failure, or network partition. A caller-owned main scaler (this disabled) must not exceed one main until deliberately switching back to multi-main with the appropriate entitlement. | `bool` | `true` | no |
| <a name="input_n8n_main_hpa_max_replicas"></a> [n8n\_main\_hpa\_max\_replicas](#input\_n8n\_main\_hpa\_max\_replicas) | Maximum replicas for n8n main pods. HPA will not scale above this. Ignored (effectively clamped to 1) while n8n\_main\_hpa\_min\_replicas=1 selects single-main topology, so a module-owned main HPA never scales a single-main deployment past its licensed ceiling of one main; raise n8n\_main\_hpa\_min\_replicas above 1 to return to multi-main and use this maximum. | `number` | `20` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replicas for n8n main pods. HPA will not scale below this. A value of 1 selects single-main topology; see n8n\_main\_hpa\_enabled for the licensing and maintenance implications. | `number` | `2` | no |
| <a name="input_n8n_main_memory_limit"></a> [n8n\_main\_memory\_limit](#input\_n8n\_main\_memory\_limit) | Memory limit for n8n main pods (e.g. 4Gi, 2Gi) | `string` | `"4Gi"` | no |
| <a name="input_n8n_main_memory_request"></a> [n8n\_main\_memory\_request](#input\_n8n\_main\_memory\_request) | Memory request for n8n main pods (e.g. 2Gi, 1Gi) | `string` | `"2Gi"` | no |
| <a name="input_n8n_metrics_enabled"></a> [n8n\_metrics\_enabled](#input\_n8n\_metrics\_enabled) | Enable n8n's built-in Prometheus metrics endpoint. When true, the module appends N8N\_METRICS=true to the n8n Helm release's config.extraEnv, which the chart applies to every n8n container (main, worker, webhook processor). n8n exposes /metrics on its existing HTTP port (5678), the same port and service the chart already publishes for the UI/API. The n8n Helm chart at the currently pinned version (see n8n\_chart\_version) exposes no top-level metrics / serviceMonitor block of its own, so this toggle is intentionally env-var-only. Scrape configuration (Prometheus scrape annotations or a ServiceMonitor CR) is left to the caller's monitoring stack, in practice the main pod's Service is the meaningful scrape target. Defaults to false; when false the env var is omitted entirely so n8n's own defaults apply. | `bool` | `false` | no |
| <a name="input_n8n_node_max_old_space_size_mb"></a> [n8n\_node\_max\_old\_space\_size\_mb](#input\_n8n\_node\_max\_old\_space\_size\_mb) | Whole MiB ceiling for Node.js's V8 old-space heap, applied identically to every n8n container (main, worker, webhook processor) via a global NODE\_OPTIONS=--max-old-space-size=<value> on config.extraEnv. Does not change the task-runner sidecar's own heap, which is a separate Node.js process outside config.extraEnv. Null (the default) omits the setting so Node's own heuristic (roughly a quarter of the container's available memory) applies. Setting this reserves NODE\_OPTIONS against n8n\_extra\_env while set; leave null to keep using n8n\_extra\_env's existing NODE\_OPTIONS escape hatch. Leave headroom below the smallest n8n container's memory limit for non-heap V8/Node overhead (code cache, native buffers, thread stacks): setting this at or above that limit risks an OOM kill instead of a controlled heap error. | `number` | `null` | no |
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
| <a name="input_n8n_queue_worker_lock_duration"></a> [n8n\_queue\_worker\_lock\_duration](#input\_n8n\_queue\_worker\_lock\_duration) | Milliseconds a worker holds an execution lease before it is considered stalled and eligible for another worker to pick up (the chart's redis.worker.lockDuration). Null (the default) omits the override so the chart's own default (60000) applies. Wired alongside n8n\_queue\_worker\_lock\_renew\_time and n8n\_queue\_worker\_stalled\_interval into one nested redis.worker chart map so partial overrides do not discard the others' values. | `number` | `null` | no |
| <a name="input_n8n_queue_worker_lock_renew_time"></a> [n8n\_queue\_worker\_lock\_renew\_time](#input\_n8n\_queue\_worker\_lock\_renew\_time) | Milliseconds between a worker's automatic renewals of its execution lease (the chart's redis.worker.lockRenewTime). Null (the default) omits the override so the chart's own default (10000) applies. Must resolve to strictly less than the effective lock duration (this input, or the chart's 60000 default when n8n\_queue\_worker\_lock\_duration is also null); otherwise the lease would expire before a renewal could ever land. | `number` | `null` | no |
| <a name="input_n8n_queue_worker_stalled_interval"></a> [n8n\_queue\_worker\_stalled\_interval](#input\_n8n\_queue\_worker\_stalled\_interval) | Milliseconds between checks for stalled jobs (jobs whose lease expired without renewal) (the chart's redis.worker.stalledInterval). Null (the default) omits the override so the chart's own default (30000) applies. | `number` | `null` | no |
| <a name="input_n8n_redis_timeout_threshold_ms"></a> [n8n\_redis\_timeout\_threshold\_ms](#input\_n8n\_redis\_timeout\_threshold\_ms) | Milliseconds n8n waits for a Redis response before treating the connection as failed (the chart's redis.timeout / QUEUE\_BULL\_REDIS\_TIMEOUT\_THRESHOLD). Must be at least 30000 when redis\_tier = STANDARD\_HA on a module-managed instance, covering Memorystore's documented ~30s average unavailability during an automated failover. | `number` | `10000` | no |
| <a name="input_n8n_reinstall_missing_packages"></a> [n8n\_reinstall\_missing\_packages](#input\_n8n\_reinstall\_missing\_packages) | Reinstall community packages that are recorded in the database but missing from a pod's local filesystem at startup. Maps to N8N\_REINSTALL\_MISSING\_PACKAGES. n8n stores installed community packages on the pod's filesystem, which is ephemeral in Kubernetes, so a rescheduled or newly scaled-up worker comes up without them and nodes installed via the UI fail to load on that pod. Enabling this makes every pod (main, worker, and webhook-processor) reinstall the recorded packages on boot, which is what lets community nodes work reliably in queue mode. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. | `bool` | `false` | no |
| <a name="input_n8n_secret_manager_enabled"></a> [n8n\_secret\_manager\_enabled](#input\_n8n\_secret\_manager\_enabled) | When true, the module grants the n8n Workload Identity Google service account roles/secretmanager.secretAccessor on every secret listed in n8n\_secret\_manager\_secret\_ids, scoped to those secrets only (never project-wide). Requires a non-empty n8n\_secret\_manager\_secret\_ids. Configuring n8n's Google Secret Manager vault-provider connection itself (Settings > External Secrets) remains an in-product operator action; this only grants the underlying GCP IAM that connection needs. Defaults to false (no Secret Manager IAM granted). | `bool` | `false` | no |
| <a name="input_n8n_secret_manager_secret_ids"></a> [n8n\_secret\_manager\_secret\_ids](#input\_n8n\_secret\_manager\_secret\_ids) | Explicit allow-list of Google Secret Manager secret resource IDs (format projects/<project>/secrets/<secret\_id>) the n8n Workload Identity service account may read. Required (non-empty) when n8n\_secret\_manager\_enabled = true. Ignored otherwise. Each entry must be a fully qualified secret resource ID with no wildcard, whitespace, or version suffix (IAM is granted at the secret level, not a specific version). | `list(string)` | `[]` | no |
| <a name="input_n8n_task_runner_auto_shutdown_timeout"></a> [n8n\_task\_runner\_auto\_shutdown\_timeout](#input\_n8n\_task\_runner\_auto\_shutdown\_timeout) | Seconds of inactivity before the runner process shuts down. Set to 0 to disable. | `number` | `15` | no |
| <a name="input_n8n_task_runner_cpu_limit"></a> [n8n\_task\_runner\_cpu\_limit](#input\_n8n\_task\_runner\_cpu\_limit) | CPU limit for task runner sidecar containers (e.g. 1, 2000m) | `string` | `"1"` | no |
| <a name="input_n8n_task_runner_cpu_request"></a> [n8n\_task\_runner\_cpu\_request](#input\_n8n\_task\_runner\_cpu\_request) | CPU request for task runner sidecar containers (e.g. 200m, 500m) | `string` | `"200m"` | no |
| <a name="input_n8n_task_runner_custom_config"></a> [n8n\_task\_runner\_custom\_config](#input\_n8n\_task\_runner\_custom\_config) | Reference to an existing ConfigMap (in the n8n namespace) holding a custom task-runner launcher configuration file (n8n-task-runners.json by default), mounted read-only at /etc/n8n-task-runners.json on the task-runner sidecar of every main and worker pod via the chart's taskRunners.customConfig. Use this to allowlist additional JavaScript/Python packages for the Code node; the module never reads the referenced ConfigMap's contents, so the whole file's contents (not a merge or patch) come from the caller and must match the exact task-runner image/version in use (n8n\_task\_runner\_image\_tag, or the inherited n8n application image tag). Changing only the ConfigMap's contents does not trigger an automatic rollout: restart the n8n-main and n8n-worker deployments to pick up new data. Leave null (the default) to leave the launcher at the chart's built-in configuration. Requires n8n\_task\_runners\_enabled = true. | <pre>object({<br/>    config_map_name = string<br/>    config_map_key  = optional(string, "n8n-task-runners.json")<br/>  })</pre> | `null` | no |
| <a name="input_n8n_task_runner_image_repository"></a> [n8n\_task\_runner\_image\_repository](#input\_n8n\_task\_runner\_image\_repository) | Container image repository for the task runner sidecar (chart default: n8nio/runners), without a tag. Leave null (the default) to use the chart's own repository. Set this alongside n8n\_task\_runner\_image\_tag when the n8n application image is mirrored into a private registry the runner image must also come from. Ignored when n8n\_task\_runners\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_task_runner_image_tag"></a> [n8n\_task\_runner\_image\_tag](#input\_n8n\_task\_runner\_image\_tag) | Image tag for the task runner sidecar (n8nio/runners, or n8n\_task\_runner\_image\_repository when set). When it is null (the default), the chart falls back to the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set this to the underlying n8n version when running a custom application image whose tag is not one (e.g. n8n\_image\_tag = "2.27.4-mypackages" together with n8n\_task\_runner\_image\_tag = "2.27.4"); otherwise the sidecar tries to pull an image tag that does not exist and every main and worker pod stays in ImagePullBackOff. Ignored when n8n\_task\_runners\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_task_runner_memory_limit"></a> [n8n\_task\_runner\_memory\_limit](#input\_n8n\_task\_runner\_memory\_limit) | Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_n8n_task_runner_memory_request"></a> [n8n\_task\_runner\_memory\_request](#input\_n8n\_task\_runner\_memory\_request) | Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi) | `string` | `"512Mi"` | no |
| <a name="input_n8n_task_runner_python_enabled"></a> [n8n\_task\_runner\_python\_enabled](#input\_n8n\_task\_runner\_python\_enabled) | Enable the native Python runner (beta). Required for Python code execution in workflows. | `bool` | `true` | no |
| <a name="input_n8n_task_runner_request_timeout"></a> [n8n\_task\_runner\_request\_timeout](#input\_n8n\_task\_runner\_request\_timeout) | Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N\_RUNNERS\_TASK\_REQUEST\_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar). | `number` | `300` | no |
| <a name="input_n8n_task_runner_timeout"></a> [n8n\_task\_runner\_timeout](#input\_n8n\_task\_runner\_timeout) | Seconds a task runner is allowed to spend executing an already-accepted Code node task before n8n cancels it. Wired to the N8N\_RUNNERS\_TASK\_TIMEOUT env var on the main and worker pods. Distinct from n8n\_task\_runner\_request\_timeout, which bounds how long n8n waits for a runner to accept a task in the first place, not how long the task itself may run; the two are deliberately independent so a busy runner (acceptance) and a long-running script (execution) can be tuned separately. | `number` | `300` | no |
| <a name="input_n8n_task_runners_enabled"></a> [n8n\_task\_runners\_enabled](#input\_n8n\_task\_runners\_enabled) | Enable task runner sidecars for isolated JavaScript and Python code execution | `bool` | `true` | no |
| <a name="input_n8n_templates_enabled"></a> [n8n\_templates\_enabled](#input\_n8n\_templates\_enabled) | Enable n8n's workflow templates and template suggestions. Maps to N8N\_TEMPLATES\_ENABLED. When false, sets N8N\_TEMPLATES\_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default, note that explicitly setting true emits no env var (n8n's default already applies). Set to false to hide the templates library, e.g. when enforcing curated internal workflows. | `bool` | `true` | no |
| <a name="input_n8n_termination_grace_period"></a> [n8n\_termination\_grace\_period](#input\_n8n\_termination\_grace\_period) | Seconds Kubernetes waits after SIGTERM before force-killing pods. MINIMUM, do not lower below 60. Workers need time to finish in-flight executions before being terminated. | `number` | `60` | no |
| <a name="input_n8n_timezone"></a> [n8n\_timezone](#input\_n8n\_timezone) | Timezone for n8n (e.g. UTC, America/New\_York, Europe/London) | `string` | `"UTC"` | no |
| <a name="input_n8n_unverified_packages_enabled"></a> [n8n\_unverified\_packages\_enabled](#input\_n8n\_unverified\_packages\_enabled) | Whether n8n allows installing community packages that have not passed n8n's verification process, mapped to N8N\_UNVERIFIED\_PACKAGES\_ENABLED on every n8n role. Null (the default) leaves n8n's own upstream default in place, so a future n8n release can change that default without this module pinning it. Set explicitly (true or false) to fix the behavior regardless of the upstream default. | `bool` | `null` | no |
| <a name="input_n8n_webhook_cpu_limit"></a> [n8n\_webhook\_cpu\_limit](#input\_n8n\_webhook\_cpu\_limit) | CPU limit for n8n webhook processor pods (e.g. 800m, 1000m) | `string` | `"800m"` | no |
| <a name="input_n8n_webhook_cpu_request"></a> [n8n\_webhook\_cpu\_request](#input\_n8n\_webhook\_cpu\_request) | CPU request for n8n webhook processor pods (e.g. 300m, 500m) | `string` | `"300m"` | no |
| <a name="input_n8n_webhook_fixed_replicas"></a> [n8n\_webhook\_fixed\_replicas](#input\_n8n\_webhook\_fixed\_replicas) | Fixed replica count for n8n webhook processor pods when n8n\_webhook\_hpa\_enabled = false. Ignored while the HPA is enabled. | `number` | `2` | no |
| <a name="input_n8n_webhook_hpa_cpu_threshold"></a> [n8n\_webhook\_hpa\_cpu\_threshold](#input\_n8n\_webhook\_hpa\_cpu\_threshold) | Target average CPU utilization (%) that triggers scaling of n8n webhook pods. | `number` | `65` | no |
| <a name="input_n8n_webhook_hpa_enabled"></a> [n8n\_webhook\_hpa\_enabled](#input\_n8n\_webhook\_hpa\_enabled) | When true (the default), the module creates and manages the HPA for n8n webhook processor pods. Set to false to let the caller own webhook-pod scaling (or run a fixed replica count); no n8n webhook HPA is rendered. n8n\_webhook\_fixed\_replicas sets the replica count while disabled. | `bool` | `true` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Maximum replicas for n8n webhook processor pods. HPA will not scale above this. | `number` | `50` | no |
| <a name="input_n8n_webhook_hpa_min_replicas"></a> [n8n\_webhook\_hpa\_min\_replicas](#input\_n8n\_webhook\_hpa\_min\_replicas) | Minimum replicas for n8n webhook processor pods. HPA will not scale below this. | `number` | `2` | no |
| <a name="input_n8n_webhook_hpa_scale_up_stabilization_window_seconds"></a> [n8n\_webhook\_hpa\_scale\_up\_stabilization\_window\_seconds](#input\_n8n\_webhook\_hpa\_scale\_up\_stabilization\_window\_seconds) | Seconds the standalone n8n webhook-processor HPA waits before acting on a scale-up recommendation, smoothing out rapidly fluctuating metric values. Maps to the HPA's behavior.scaleUp.stabilizationWindowSeconds. 0 (the default) matches Kubernetes' own scale-up default (react immediately); the chart's built-in main/worker scaling is unaffected. Ignored when n8n\_webhook\_hpa\_enabled = false, since no webhook HPA is rendered in that case. | `number` | `0` | no |
| <a name="input_n8n_webhook_memory_limit"></a> [n8n\_webhook\_memory\_limit](#input\_n8n\_webhook\_memory\_limit) | Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_n8n_webhook_memory_request"></a> [n8n\_webhook\_memory\_request](#input\_n8n\_webhook\_memory\_request) | Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi) | `string` | `"512Mi"` | no |
| <a name="input_n8n_webhook_url"></a> [n8n\_webhook\_url](#input\_n8n\_webhook\_url) | Public HTTPS base URL used for webhook callbacks (e.g. https://webhooks.example.com). Defaults to https://<n8n\_fqdn> when not set. Override when webhooks are served from a different host than the n8n UI. | `string` | `null` | no |
| <a name="input_n8n_worker_concurrency"></a> [n8n\_worker\_concurrency](#input\_n8n\_worker\_concurrency) | Number of jobs each worker pod can process simultaneously | `number` | `10` | no |
| <a name="input_n8n_worker_cpu_limit"></a> [n8n\_worker\_cpu\_limit](#input\_n8n\_worker\_cpu\_limit) | CPU limit for n8n worker pods (e.g. 1000m, 2000m) | `string` | `"1000m"` | no |
| <a name="input_n8n_worker_cpu_request"></a> [n8n\_worker\_cpu\_request](#input\_n8n\_worker\_cpu\_request) | CPU request for n8n worker pods (e.g. 500m, 1000m) | `string` | `"500m"` | no |
| <a name="input_n8n_worker_fixed_replicas"></a> [n8n\_worker\_fixed\_replicas](#input\_n8n\_worker\_fixed\_replicas) | Fixed replica count for n8n worker pods when n8n\_worker\_keda\_enabled = false. Ignored while KEDA scaling is enabled. | `number` | `1` | no |
| <a name="input_n8n_worker_keda_enabled"></a> [n8n\_worker\_keda\_enabled](#input\_n8n\_worker\_keda\_enabled) | When true (the default), the module creates and manages the KEDA ScaledObject for n8n worker pods. Set to false to let the caller own worker scaling (or run a fixed replica count); no n8n worker ScaledObject is rendered. n8n\_worker\_fixed\_replicas sets the replica count while disabled. | `bool` | `true` | no |
| <a name="input_n8n_worker_keda_jobs_per_replica"></a> [n8n\_worker\_keda\_jobs\_per\_replica](#input\_n8n\_worker\_keda\_jobs\_per\_replica) | Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue\_depth / jobs\_per\_replica) replicas. | `number` | `5` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Maximum worker replicas KEDA may scale to. | `number` | `10` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty. | `number` | `1` | no |
| <a name="input_n8n_worker_memory_limit"></a> [n8n\_worker\_memory\_limit](#input\_n8n\_worker\_memory\_limit) | Memory limit for n8n worker pods (e.g. 2Gi, 4Gi) | `string` | `"2Gi"` | no |
| <a name="input_n8n_worker_memory_request"></a> [n8n\_worker\_memory\_request](#input\_n8n\_worker\_memory\_request) | Memory request for n8n worker pods (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_pods_cidr"></a> [pods\_cidr](#input\_pods\_cidr) | Secondary range for GKE pods (VPC-native / alias IPs). | `string` | `"10.20.0.0/16"` | no |
| <a name="input_postgres_availability_type"></a> [postgres\_availability\_type](#input\_postgres\_availability\_type) | REGIONAL for HA (failover replica), ZONAL for single-zone. | `string` | `"REGIONAL"` | no |
| <a name="input_postgres_clone_point_in_time"></a> [postgres\_clone\_point\_in\_time](#input\_postgres\_clone\_point\_in\_time) | RFC3339 timestamp to clone postgres\_clone\_source\_instance\_name from a specific point in time (requires point-in-time recovery enabled on the source). Requires postgres\_clone\_source\_instance\_name when set. | `string` | `null` | no |
| <a name="input_postgres_clone_source_instance_name"></a> [postgres\_clone\_source\_instance\_name](#input\_postgres\_clone\_source\_instance\_name) | Name of an existing Cloud SQL instance to clone from when creating the module-managed instance (the resource's clone block). Mutually exclusive with postgres\_restore\_backup\_run\_id. Ignored when create\_postgres\_instance = false. Only takes effect the first time the instance is created; it has no effect on an already-created instance. | `string` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_disk_size"></a> [postgres\_disk\_size](#input\_postgres\_disk\_size) | Cloud SQL data disk size in GB. | `number` | `50` | no |
| <a name="input_postgres_edition"></a> [postgres\_edition](#input\_postgres\_edition) | Cloud SQL edition. ENTERPRISE supports shared-core/legacy tiers like db-g1-small (cheap, dev). ENTERPRISE\_PLUS requires db-perf-optimized-N-* tiers. Pinned because some projects/orgs default new instances to ENTERPRISE\_PLUS, which rejects db-g1-small. | `string` | `"ENTERPRISE"` | no |
| <a name="input_postgres_machine_type"></a> [postgres\_machine\_type](#input\_postgres\_machine\_type) | Cloud SQL machine tier. ENTERPRISE: e.g. db-g1-small, db-custom-2-7680. ENTERPRISE\_PLUS: e.g. db-perf-optimized-N-2. Must be compatible with postgres\_edition. | `string` | `"db-g1-small"` | no |
| <a name="input_postgres_restore_backup_run_id"></a> [postgres\_restore\_backup\_run\_id](#input\_postgres\_restore\_backup\_run\_id) | Backup run ID to restore into the module-managed Cloud SQL instance at creation (the resource's restore\_backup\_context block). Requires postgres\_restore\_source\_instance\_name. Mutually exclusive with postgres\_clone\_source\_instance\_name. Ignored when create\_postgres\_instance = false. | `number` | `null` | no |
| <a name="input_postgres_restore_source_instance_name"></a> [postgres\_restore\_source\_instance\_name](#input\_postgres\_restore\_source\_instance\_name) | Name of the Cloud SQL instance that owns the backup named by postgres\_restore\_backup\_run\_id. Must be set together with postgres\_restore\_backup\_run\_id. | `string` | `null` | no |
| <a name="input_postgres_version"></a> [postgres\_version](#input\_postgres\_version) | Cloud SQL Postgres version. | `string` | `"POSTGRES_16"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID to deploy into. | `string` | n/a | yes |
| <a name="input_psa_cleanup_destroy_duration"></a> [psa\_cleanup\_destroy\_duration](#input\_psa\_cleanup\_destroy\_duration) | How long to pause on destroy after Cloud SQL/Memorystore are deleted before deleting the Private Services Access peering, giving GCP's backend time to release its hold on the connection. GCP does not report when the release completes, and the observed lag varies widely (minutes to well over an hour). If destroy still fails with 'Producer services ... are still using this connection', either raise this or use the compute-level peering-delete escape hatch documented in README.md ('Teardown'). Accepts Go duration syntax (e.g. "3m", "15m", "1h"). | `string` | `"3m"` | no |
| <a name="input_psa_prefix_length"></a> [psa\_prefix\_length](#input\_psa\_prefix\_length) | Prefix length for the Private Services Access range that Cloud SQL / Memorystore peer into. | `number` | `16` | no |
| <a name="input_redis_auth_enabled"></a> [redis\_auth\_enabled](#input\_redis\_auth\_enabled) | Enable Redis AUTH on the module-managed Memorystore instance. If true, the KEDA worker trigger gets a TriggerAuthentication CRD referencing the generated AUTH string. | `bool` | `false` | no |
| <a name="input_redis_host"></a> [redis\_host](#input\_redis\_host) | External Redis host. Required when create\_redis\_instance = false. Ignored otherwise (n8n and KEDA use the module-managed Memorystore host). | `string` | `null` | no |
| <a name="input_redis_key_prefix"></a> [redis\_key\_prefix](#input\_redis\_key\_prefix) | Optional prefix n8n applies to both its command channel (N8N\_REDIS\_KEY\_PREFIX, n8n default "n8n") and its Bull queue Redis keys (the chart's redis.prefix, chart default "bull"), synchronized with the corresponding KEDA queue list names ("<prefix>:jobs:wait" / "<prefix>:jobs:active") and, when enabled, the Redis exporter's queue-key checks. Leave null (the default) to use n8n's and the chart's own distinct default prefixes. Changing this value on a deployment with in-flight or queued jobs strands them under the old prefix; drain the queue first (see docs/customer-managed-infrastructure.md). | `string` | `null` | no |
| <a name="input_redis_memory_size_gb"></a> [redis\_memory\_size\_gb](#input\_redis\_memory\_size\_gb) | Memorystore capacity in GB. | `number` | `1` | no |
| <a name="input_redis_password"></a> [redis\_password](#input\_redis\_password) | Optional direct password for the external Redis host. Mutually exclusive with redis\_password\_secret\_ref. Ignored when create\_redis\_instance = true (the module manages Memorystore AUTH via redis\_auth\_enabled instead). | `string` | `null` | no |
| <a name="input_redis_password_secret_ref"></a> [redis\_password\_secret\_ref](#input\_redis\_password\_secret\_ref) | Reference to an existing Kubernetes Secret (in the n8n namespace) holding the external Redis password, instead of passing the value directly through redis\_password. key defaults to "password" when omitted. The module never reads the referenced Secret's value; it only passes the reference through to the n8n Helm chart's redis.passwordSecret and to KEDA's TriggerAuthentication. Mutually exclusive with redis\_password. Both are optional (unlike PostgreSQL, external Redis may run without a password). Ignored when create\_redis\_instance = true. | <pre>object({<br/>    name = string<br/>    key  = optional(string, "password")<br/>  })</pre> | `null` | no |
| <a name="input_redis_port"></a> [redis\_port](#input\_redis\_port) | External Redis port. Ignored when create\_redis\_instance = true (Memorystore always uses 6379). | `number` | `6379` | no |
| <a name="input_redis_tier"></a> [redis\_tier](#input\_redis\_tier) | Memorystore tier: BASIC (no replica) or STANDARD\_HA (adds a replica and automated failover). | `string` | `"BASIC"` | no |
| <a name="input_redis_tls_enabled"></a> [redis\_tls\_enabled](#input\_redis\_tls\_enabled) | Whether n8n and KEDA connect to the external Redis host over TLS. Ignored when create\_redis\_instance = true (managed Memorystore transit encryption is controlled separately). | `bool` | `false` | no |
| <a name="input_redis_transit_encryption_enabled"></a> [redis\_transit\_encryption\_enabled](#input\_redis\_transit\_encryption\_enabled) | Enable in-transit (TLS) encryption on the module-managed Memorystore instance (transit\_encryption\_mode = SERVER\_AUTHENTICATION). n8n and KEDA connect over TLS when set. Ignored when create\_redis\_instance = false; use redis\_tls\_enabled for an external Redis host instead. | `bool` | `false` | no |
| <a name="input_redis_username"></a> [redis\_username](#input\_redis\_username) | Optional ACL username for the external Redis host (Redis 6+ ACL-compatible services). Ignored when create\_redis\_instance = true. Passed to n8n as a plain chart value and wrapped in a module-managed Secret purely so KEDA's TriggerAuthentication can reference it too. | `string` | `null` | no |
| <a name="input_redis_version"></a> [redis\_version](#input\_redis\_version) | Memorystore Redis version. | `string` | `"REDIS_7_2"` | no |
| <a name="input_services_cidr"></a> [services\_cidr](#input\_services\_cidr) | Secondary range for GKE services (VPC-native / alias IPs). | `string` | `"10.30.0.0/20"` | no |
| <a name="input_subnet_cidr"></a> [subnet\_cidr](#input\_subnet\_cidr) | Primary CIDR for the node subnet. | `string` | `"10.10.0.0/20"` | no |
| <a name="input_tls_cert_pem"></a> [tls\_cert\_pem](#input\_tls\_cert\_pem) | PEM certificate chain (tls\_mode = custom), e.g. a Cloudflare Origin CA cert. | `string` | `""` | no |
| <a name="input_tls_key_pem"></a> [tls\_key\_pem](#input\_tls\_key\_pem) | PEM private key (tls\_mode = custom). | `string` | `""` | no |
| <a name="input_tls_mode"></a> [tls\_mode](#input\_tls\_mode) | How the LB gets its cert (base module, provider-clean):<br/>  - "google\_managed" : ManagedCertificate CRD, auto-renew. DEFAULT. Validated end to end; the DNS A-record must point at the LB static IP before the cert can provision.<br/>  - "custom"         : bring your own PEM (tls\_cert\_pem/tls\_key\_pem), e.g. a Cloudflare Origin CA cert, uploaded as a pre-shared cert.<br/>  - "secret"         : the gce Ingress consumes an existing k8s TLS Secret (tls\_secret\_name). This is how examples/cloudflare wires Let's Encrypt via cert-manager.<br/>  - "self\_signed"    : instant cert with a browser warning, for smoke tests before DNS is live. | `string` | `"google_managed"` | no |
| <a name="input_tls_secret_name"></a> [tls\_secret\_name](#input\_tls\_secret\_name) | Name of an existing Kubernetes TLS Secret the Ingress should use (tls\_mode = secret). Populated by an external issuer such as cert-manager in examples/cloudflare. | `string` | `"n8n-tls"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | Effective GCS bucket used for n8n binary storage: module-created or the supplied existing\_gcs\_bucket\_name. |
| <a name="output_gcs_hmac_access_id"></a> [gcs\_hmac\_access\_id](#output\_gcs\_hmac\_access\_id) | GCS HMAC access key ID for the n8n S3-compatible binary storage driver (module-created or caller-supplied in BYO mode). |
| <a name="output_gcs_hmac_secret"></a> [gcs\_hmac\_secret](#output\_gcs\_hmac\_secret) | GCS HMAC secret for the n8n S3-compatible binary storage driver. Null in BYO mode when supplied via an existing Secret (gcs\_hmac\_secret\_name). |
| <a name="output_gcs_kms_key_id"></a> [gcs\_kms\_key\_id](#output\_gcs\_kms\_key\_id) | Effective Cloud KMS key ID protecting the module-managed GCS bucket: the module-created key, the supplied existing\_gcs\_kms\_key\_id, or null for Google-managed encryption. Always null when create\_gcs\_bucket = false. |
| <a name="output_gke_cluster_ca_certificate"></a> [gke\_cluster\_ca\_certificate](#output\_gke\_cluster\_ca\_certificate) | Effective base64-encoded GKE cluster CA. Pass to kubernetes/helm providers as cluster\_ca\_certificate (after base64decode). Resolves to the module-managed cluster's CA, or to the existing cluster named by existing\_gke\_cluster\_name. |
| <a name="output_gke_cluster_endpoint"></a> [gke\_cluster\_endpoint](#output\_gke\_cluster\_endpoint) | Effective GKE control-plane endpoint. Pass to the kubernetes/helm providers as host (https://<endpoint>). Resolves to the module-managed cluster's endpoint, or to the existing cluster named by existing\_gke\_cluster\_name. |
| <a name="output_gke_cluster_name"></a> [gke\_cluster\_name](#output\_gke\_cluster\_name) | Effective GKE cluster name: module-managed, or the supplied existing\_gke\_cluster\_name. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_lb_ingress_ip"></a> [lb\_ingress\_ip](#output\_lb\_ingress\_ip) | IP the module-managed Ingress reports once the LB is provisioned (should match static\_ip). Null when create\_ingress = false; the caller's own ingress reports its own address. |
| <a name="output_n8n_database_password"></a> [n8n\_database\_password](#output\_n8n\_database\_password) | Database password. Module-managed when create\_postgres\_instance = true, else the effective direct/Secret-reference value (null when supplied only via n8n\_database\_password\_secret\_ref, which the module never reads). |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key: the direct n8n\_encryption\_key when supplied, else the generated key. Back this up; losing it makes all stored credentials unreadable. Null when existing\_n8n\_core\_secret\_name supplies an existing core Secret; the module generates and reads no encryption key on that path. |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | Kubernetes namespace n8n is deployed into. |
| <a name="output_n8n_main_route_prefixes"></a> [n8n\_main\_route\_prefixes](#output\_n8n\_main\_route\_prefixes) | Path prefixes that must route to n8n\_main\_service\_name. |
| <a name="output_n8n_main_service_name"></a> [n8n\_main\_service\_name](#output\_n8n\_main\_service\_name) | Kubernetes Service name that serves n8n's main UI/API traffic. |
| <a name="output_n8n_service_port"></a> [n8n\_service\_port](#output\_n8n\_service\_port) | Port both the main and webhook Services listen on. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once DNS propagates and the cert is active |
| <a name="output_n8n_webhook_route_prefixes"></a> [n8n\_webhook\_route\_prefixes](#output\_n8n\_webhook\_route\_prefixes) | Path prefixes that must route to n8n\_webhook\_service\_name: /webhook, /webhook-waiting, /form, /form-waiting, and /mcp. |
| <a name="output_n8n_webhook_service_name"></a> [n8n\_webhook\_service\_name](#output\_n8n\_webhook\_service\_name) | Kubernetes Service name that serves n8n's webhook traffic. |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | Effective network ID: the module-created VPC, or the supplied existing\_network\_name. |
| <a name="output_postgres_connection_name"></a> [postgres\_connection\_name](#output\_postgres\_connection\_name) | Cloud SQL instance connection name (project:region:instance). Null when create\_postgres\_instance = false. |
| <a name="output_postgres_host"></a> [postgres\_host](#output\_postgres\_host) | Effective PostgreSQL host: the module-managed Cloud SQL private IP, or the supplied external n8n\_database\_host. |
| <a name="output_postgres_kms_key_id"></a> [postgres\_kms\_key\_id](#output\_postgres\_kms\_key\_id) | Effective Cloud KMS key ID protecting the module-managed Cloud SQL instance: the module-created key, the supplied existing\_postgres\_kms\_key\_id, or null for Google-managed encryption. Always null when create\_postgres\_instance = false. |
| <a name="output_postgres_private_ip"></a> [postgres\_private\_ip](#output\_postgres\_private\_ip) | Cloud SQL private IP (VPC-internal). Null when create\_postgres\_instance = false; use postgres\_host or n8n\_database\_host instead. |
| <a name="output_redis_host"></a> [redis\_host](#output\_redis\_host) | Effective Redis host: the module-managed Memorystore host, or the supplied external redis\_host. |
| <a name="output_redis_kms_key_id"></a> [redis\_kms\_key\_id](#output\_redis\_kms\_key\_id) | Effective Cloud KMS key ID protecting the module-managed Memorystore instance: the module-created key, the supplied existing\_redis\_kms\_key\_id, or null for Google-managed encryption. Always null when create\_redis\_instance = false. |
| <a name="output_redis_port"></a> [redis\_port](#output\_redis\_port) | Effective Redis port: 6379 for module-managed Memorystore, or the supplied external redis\_port. |
| <a name="output_redis_tls_enabled"></a> [redis\_tls\_enabled](#output\_redis\_tls\_enabled) | Whether the effective Redis connection uses TLS: redis\_transit\_encryption\_enabled for module-managed Memorystore, or the supplied external redis\_tls\_enabled. |
| <a name="output_redis_username"></a> [redis\_username](#output\_redis\_username) | Effective external Redis ACL username (redis\_username). Always null for module-managed Memorystore, which has no concept of one. |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | Reserved global static IP of the module-managed L7 load balancer. Point n8n\_fqdn (an A record) at this. The base module creates the record when cloud\_dns\_zone\_name is set; otherwise create it in your DNS provider (as examples/cloudflare does). Null when create\_ingress = false; the caller owns the load balancer and its address. |
| <a name="output_subnetwork_self_link"></a> [subnetwork\_self\_link](#output\_subnetwork\_self\_link) | Effective subnetwork self-link: the module-created subnet, or the supplied existing\_subnetwork\_name. |
| <a name="output_workload_identity_pool"></a> [workload\_identity\_pool](#output\_workload\_identity\_pool) | Effective Workload Identity pool the n8n Google service account is bound into (<project\_id>.svc.id.goog, or existing\_gke\_workload\_identity\_pool for a cross-project existing cluster). |
| <a name="output_workload_identity_service_account"></a> [workload\_identity\_service\_account](#output\_workload\_identity\_service\_account) | Google service account the n8n pods impersonate via Workload Identity. |
<!-- END_TF_DOCS -->

