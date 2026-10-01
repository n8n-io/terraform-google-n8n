# Troubleshooting

Issues observed in real deployments and how to resolve them. If you hit something not covered here, open an issue.

Upgrading from an earlier interface (topology transitions, newly reserved
environment variables, corrected URLs, Redis prefix changes)? See
[`docs/upgrading-n8n.md`](./upgrading-n8n.md) first.

## `terraform apply`: `no cached repo found ... hashicorp-index.yaml`

**Symptom**

One or more `helm_release` resources fail at create time with:

```
Error: could not download chart: no cached repo found.
(try 'helm repo update'):
open /Users/<you>/Library/Caches/helm/repository/<repo>-index.yaml: no such file or directory
```

**Cause**

The `hashicorp/helm` Terraform provider embeds the Helm SDK v3 and reuses the local Helm CLI's repository cache (`$HELM_REPOSITORY_CACHE`). This is still true on the `~> 3.0` provider line this module pins: provider 3.x is a Plugin Framework rewrite, but it continues to vendor `helm.sh/helm/v3`, so the embedded SDK is unchanged from the 2.x era. When the system Helm CLI is **Helm 4** (released 2025), the cache layout differs slightly from the v3 SDK's expectations and the SDK fails to find the index files even though the chart URL is hard-coded in the `helm_release` block.

This is environmental, not a module bug, but anyone running Helm 4 on macOS will see it. (Note: if the repository cache is already populated, for example from earlier `helm repo add`/`helm repo update` runs, the apply succeeds without intervention; the failure only appears against an empty or Helm-4-only cache.)

**Fix**

Pre-populate the v3-compatible cache once before the first apply:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
```

Then re-run `terraform apply`. Already-created resources are skipped; only the failed `helm_release`s are retried.

If your environment supports it, downgrading to Helm 3 also resolves the issue:

```bash
brew uninstall helm
brew install helm@3
```

## `ManagedCertificate` stuck in `Provisioning`

**Symptom**

With `tls_mode = "google_managed"` (the default), `kubectl get managedcertificate -n <n8n_kube_namespace>` shows `Provisioning` well past the few minutes it normally takes, and HTTPS to `n8n_fqdn` fails or falls back to a default/self-signed certificate.

**Cause**

Google's `ManagedCertificate` controller only issues a certificate once the domain in `spec.domains` (the module's `n8n_fqdn`) resolves, via DNS, to the load balancer's `static_ip`. If the A-record does not exist yet, points at the wrong IP, or has not propagated, the certificate sits in `Provisioning` indefinitely, there is no timeout or error surfaced beyond `kubectl describe managedcertificate`.

This most often happens when `cloud_dns_zone_name` is left empty (the module does not manage DNS) and the operator has not yet created the A-record at their own DNS provider, or when a stale record from a previous deployment still points at a different IP.

**Fix**

1. Confirm the static IP: `terraform output -raw static_ip`.
2. Confirm DNS resolves to it: `dig +short n8n.yourdomain.com`.
3. If it doesn't, create or correct the A-record (see [`post-deployment.md`](./post-deployment.md)).
4. Re-check status: `kubectl describe managedcertificate -n <n8n_kube_namespace>`. The `status.domainStatus` field lists a per-domain state (`FailedNotVisible` means DNS still doesn't resolve to the LB from Google's perspective).

Once DNS is correct, provisioning typically completes within a few minutes; no `terraform apply` is needed, the controller reconciles on its own.

## Smoke test reports `HTTP 000` after a recent destroy + re-apply

**Symptom**

`tests/scripts/smoke-test.sh` fails the HTTP health, redirect, and API checks with `HTTP 000` against the n8n URL. Direct `dig n8n.example.com` resolves correctly, but `curl https://n8n.example.com/healthz` exits with code 6 (`CURLE_COULDNT_RESOLVE_HOST`).

**Cause (macOS)**

`mDNSResponder` cached the NXDOMAIN response from the previous deployment's destroy phase and is serving it for 5-15 minutes even after Terraform re-created the DNS A-record. `dig` and `host` bypass `mDNSResponder`; `curl`, browsers, and anything else using `getaddrinfo()` do not.

This only reproduces when the same FQDN is reused across consecutive `apply` -> `destroy` -> `apply` cycles on the same workstation, which is common during iterative development of this module but unusual in production.

**Fix**

Flush the macOS DNS cache:

```bash
sudo killall -HUP mDNSResponder
```

Or wait for the negative cache to age out (typically 5-15 minutes). To avoid the issue entirely, use a fresh subdomain per deployment.

## Workload Identity: pods can't reach Cloud SQL or GCS

**Symptom**

n8n pods crash-loop or log permission-denied errors calling Cloud SQL or GCS, even though `google_project_iam_member.n8n_cloudsql_client` and the storage bucket IAM binding exist in state.

**Cause**

Workload Identity binds a Kubernetes ServiceAccount (KSA) to a Google service account (GSA) via an annotation plus an IAM policy binding (`google_service_account_iam_member.n8n_workload_identity`), not via a mounted key file. If the n8n Helm chart's `serviceAccount.name` does not match `n8n_kube_svc_account`, or the pod was scheduled before the KSA annotation propagated, the pod authenticates as the GKE node's default identity instead of the intended GSA and every Google API call is denied.

**Fix**

1. Confirm the KSA is annotated: `kubectl get serviceaccount <n8n_kube_svc_account> -n <n8n_kube_namespace> -o yaml` should show `iam.gke.io/gcp-service-account: <workload_identity_service_account output>`.
2. Confirm the pod actually uses that KSA: `kubectl get pod <pod> -n <n8n_kube_namespace> -o jsonpath='{.spec.serviceAccountName}'`.
3. If either is wrong, restart the affected pods after fixing the mismatch (a fresh pod picks up the metadata server token immediately; existing pods do not refresh mid-flight).

## `terraform destroy` hangs on namespace, finalizers, or PSA peering

See [destroy-cleanup.md](./destroy-cleanup.md).

## Existing GKE cluster: provider fails before the first plan

**Symptom**

With `create_gke = false`, `terraform plan` fails immediately on the
`kubernetes`/`helm`/`kubectl` provider blocks (connection refused, `no such
host`, or a 401/403 from the Kubernetes API), before any resource is even
evaluated.

**Cause**

These providers need a real cluster endpoint and CA certificate at
configuration time. When the module creates the cluster
(`create_gke = true`), the standard examples defer that configuration behind
a `data.google_container_cluster` or the module's own outputs, which only
resolve after the cluster exists. Against an existing cluster, your root must
supply working credentials and the correct endpoint from the very first plan,
typically via `data.google_client_config` and
`data.google_container_cluster.existing` in your own `providers.tf` (see
[`examples/customer-managed-cluster/providers.tf`](../examples/customer-managed-cluster/providers.tf)).

**Fix**

1. Confirm your active identity can read the cluster:
   `gcloud container clusters describe <existing_gke_cluster_name> --region <gcp_region>`.
2. Confirm the provider blocks reference `data.google_container_cluster.existing`
   (or the module's `gke_cluster_endpoint`/`gke_cluster_ca_certificate` outputs
   from a separate, already-applied root), not a hard-coded or stale endpoint.
3. Re-run `gcloud auth application-default login` if credentials expired.

## Existing GKE cluster: Workload Identity propagation lag

**Symptom**

n8n pods on an existing cluster crash-loop with Google API permission errors
immediately after the first apply, but the same configuration works fine on a
subsequent `apply` with no changes.

**Cause**

The IAM policy binding
(`google_service_account_iam_member.n8n_workload_identity`) that lets the
Kubernetes ServiceAccount impersonate the Google service account can take up
to a couple of minutes to propagate through Google's IAM backend, longer than
a module-managed cluster's own node-pool provisioning time usually leaves to
absorb. On a pre-existing cluster the n8n pods can schedule and start well
before that binding is visible.

**Fix**

Restart the affected pods once the binding has had time to propagate:

```bash
kubectl -n <n8n_kube_namespace> rollout restart deployment
```

See also
[Workload Identity: pods can't reach Cloud SQL or GCS](#workload-identity-pods-cant-reach-cloud-sql-or-gcs)
above for the general annotation/ServiceAccount-mismatch case.

## Referenced Secret errors (PostgreSQL, Redis, GCS HMAC, license, core, credential overwrites)

**Symptom**

The n8n Helm release fails at install/upgrade with a Kubernetes error like
`secret "<name>" not found`, or n8n pods start but immediately fail to
authenticate to the database, Redis, or GCS. For
`n8n_credentials_overwrite_secret_ref` specifically, pods instead fail to
*schedule* at all: `kubectl describe pod` shows `MountVolume.SetUp failed for
volume "credentials-overwrite"` with either `secret "<name>" not found` (the
Secret itself is missing) or `references non-existent secret key` (the
Secret exists but not the referenced `key`), because mounting a single Secret
key as a file is a kubelet-level operation that happens before the n8n
process ever starts.

**Cause**

A `*_secret_ref` input (`n8n_database_password_secret_ref`,
`redis_password_secret_ref`, `n8n_license_key_secret_ref`,
`existing_n8n_core_secret_name`, `gcs_hmac_secret_name`,
`n8n_credentials_overwrite_secret_ref`) only passes a *reference* through to
the chart; the module never creates, reads, or validates the referenced
Secret's existence or contents. A typo in the name, a wrong key inside the
Secret, or a Secret created in the wrong namespace all surface only once the
chart tries to mount it.

**Fix**

1. Confirm the Secret exists in the effective namespace:
   `kubectl get secret <name> -n <n8n_kube_namespace>`.
2. Confirm the key matches what you referenced (default `password` for
   database/Redis, `license-key` for the license, `accessSecret` for GCS
   HMAC; there is no default key for `n8n_credentials_overwrite_secret_ref`,
   both `name` and `key` are required):
   `kubectl get secret <name> -n <n8n_kube_namespace> -o jsonpath='{.data}'`.
3. Re-create the Secret with the correct name/key, then re-run
   `terraform apply` (Helm re-reconciles the release; Terraform itself holds
   no state for a Secret it never created).

## Credential-overwrite Secret content changes need a manual restart

**Symptom**

You updated the contents of the Secret referenced by
`n8n_credentials_overwrite_secret_ref` (e.g. rotated a prefilled OAuth
client secret), but n8n keeps using the old overwrite values.

**Cause**

The module mounts the selected key read-only at
`/etc/n8n/credentials-overwrite/overwrites.json` on every n8n role and sets
`CREDENTIALS_OVERWRITE_DATA_FILE` to that path; it never reads, hashes, or
copies the Secret's contents, so there is nothing for Terraform or the chart
to diff and no automatic Secret-hash-triggered rollout happens when only the
Secret's data changes (unlike a `terraform apply` that changes the Secret
*reference* itself, which does trigger a Helm upgrade). n8n also only reads
`CREDENTIALS_OVERWRITE_DATA_FILE` at process startup, so an already-running
pod keeps its old in-memory overwrites even after the mounted file's
contents update via kubelet's periodic Secret sync.

**Fix**

After changing the Secret's data (not its name/key reference), manually
restart all three n8n deployments so every pod re-reads the file on startup:

```bash
kubectl -n <n8n_kube_namespace> rollout restart deployment n8n-main n8n-worker n8n-webhook-processor
```

## Task-runner custom launcher configuration needs a matching image and a manual restart

**Symptom**

You set `n8n_task_runner_custom_config` to allowlist an additional package for
the Code node, but the task runner still rejects the package, ignores your
changes, or the sidecar container fails to start with a config-parsing error.

**Cause**

`n8n_task_runner_custom_config` only passes a ConfigMap name/key reference to
the chart's `taskRunners.customConfig`; the module never reads, validates, or
merges the referenced file's contents. Two behaviors follow directly from
that:

- **Whole-file replacement, not a merge.** The mounted file entirely replaces
  the task runner launcher's built-in configuration; it is not layered on top
  of, or merged with, the image's default allowlist. A config that omits the
  packages the built-in default normally allows loses access to those
  packages too.
- **Image-version alignment.** The launcher configuration file's schema and
  supported keys are defined by the exact task-runner image in use
  (`n8n_task_runner_image_tag`, or the n8n application image's tag when that
  is left null). A config written for one runner version can fail to parse,
  or silently ignore fields, on a different version.
- **No automatic rollout on content changes**, for the same reason as
  `n8n_credentials_overwrite_secret_ref` above: the module never reads the
  ConfigMap's data, so a `terraform apply` that only changes the ConfigMap's
  contents (not the `n8n_task_runner_custom_config` reference itself) gives
  Terraform and the chart nothing to diff.

**Fix**

1. Confirm the ConfigMap's contents match the schema the running task-runner
   image expects; check the image's own release notes for the version named
   by `n8n_task_runner_image_tag` (or the n8n application image tag).
2. After changing the ConfigMap's data, manually restart the two deployments
   that run the task-runner sidecar so every pod re-reads the file on
   startup:

   ```bash
   kubectl -n <n8n_kube_namespace> rollout restart deployment n8n-main n8n-worker
   ```

## Disruptive Redis transitions (prefix change, ownership switch)

See
[Disruptive Redis transitions](./customer-managed-infrastructure.md#disruptive-redis-transitions)
in the customer-managed infrastructure guide: changing `redis_key_prefix`, or
flipping `create_redis_instance`, on a deployment with in-flight or queued
jobs strands them under the old prefix or endpoint. Drain the queue first.

## KEDA finalizers block namespace or ScaledObject teardown

**Symptom**

`terraform destroy` (or a plain `kubectl delete namespace`) hangs with
`ScaledObject`/`TriggerAuthentication` custom resources stuck `Terminating`.

**Cause**

KEDA's admission webhook and operator attach finalizers to these custom
resources. If the KEDA operator (module-installed or
`existing_keda_prerequisites_attestation`-supplied) is already uninstalled,
or its webhook is unreachable, the finalizer never clears on its own.

**Fix**

See
[Namespace stuck in Terminating](./destroy-cleanup.md#namespace-stuck-in-terminating)
for the finalizer-stripping loop; run it before KEDA itself is removed
whenever possible, stripping finalizers after KEDA is already gone is the
fallback, not the first choice.

## Cloud KMS: managed resource fails to create with a permission error

**Symptom**

`google_sql_database_instance.n8n`, `google_redis_instance.n8n`,
`google_storage_bucket.n8n`, or `google_container_cluster.n8n` fails to
create/update with a permission-denied error referencing the Cloud KMS key.

**Cause**

A module-created CMEK key (`create_postgres_kms_key`/`create_redis_kms_key`/
`create_gcs_kms_key`/`create_gke_kms_key`) automatically grants the correct
service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter`. A supplied
*existing* key (`existing_postgres_kms_key_id`/`existing_redis_kms_key_id`/
`existing_gcs_kms_key_id`/`existing_gke_kms_key_id`) gets no IAM from the
module by design, see
[Cloud KMS permissions](./customer-managed-infrastructure.md#cloud-kms-permissions).

**Fix**

Grant the relevant service agent the encrypter/decrypter role on the
existing key out of band, then re-run `terraform apply`:

```bash
# Cloud SQL
gcloud kms keys add-iam-policy-binding <key> --keyring <ring> --location <loc> \
  --member="serviceAccount:service-<project_number>@gcp-sa-cloud-sql.iam.gserviceaccount.com" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter

# Memorystore
gcloud kms keys add-iam-policy-binding <key> --keyring <ring> --location <loc> \
  --member="serviceAccount:service-<project_number>@cloud-redis.iam.gserviceaccount.com" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter

# GCS
gcloud kms keys add-iam-policy-binding <key> --keyring <ring> --location <loc> \
  --member="serviceAccount:service-<project_number>@gs-project-accounts.iam.gserviceaccount.com" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter

# GKE
gcloud kms keys add-iam-policy-binding <key> --keyring <ring> --location <loc> \
  --member="serviceAccount:service-<project_number>@container-engine-robot.iam.gserviceaccount.com" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter
```

## Customer-managed ingress: webhook traffic hits the wrong service

**Symptom**

Webhook or MCP calls are slow, get rate-limited, or interfere with UI/API
traffic, even though the deployment otherwise works.

**Cause**

A hand-built ingress (`create_ingress = false`) routed one or more of
`n8n_webhook_route_prefixes` (`/webhook`, `/webhook-waiting`, `/form`,
`/form-waiting`, `/mcp`) to `n8n_main_service_name` instead of
`n8n_webhook_service_name`, defeating the point of dedicated webhook
processor pods, see
[Ingress route ownership](./customer-managed-infrastructure.md#ingress-route-ownership).

**Fix**

Update the ingress rules so every prefix in `n8n_webhook_route_prefixes`
targets `n8n_webhook_service_name`, and every other path targets
`n8n_main_service_name`, both on `n8n_service_port`.

## Customer-managed resource teardown: destroy touches something you own

**Symptom**

A `terraform plan -destroy` (or an actual `destroy`) on a mixed-ownership
deployment shows a change to a resource you expected to be entirely
customer-managed (an existing network, cluster, database, Redis instance,
bucket, namespace, or KMS key).

**Cause**

This should never happen: every customer-managed layer uses `count = 0` /
`for_each = {}` for the resources it would otherwise create. A change here
usually means a variable was left at its module-managed default (e.g.
`create_gke` accidentally left `true`) rather than explicitly set to `false`.

**Fix**

Re-check every ownership switch in your `terraform.tfvars` against the
[ownership matrix](./customer-managed-infrastructure.md#ownership-matrix), and
run `terraform plan -destroy` again before confirming a real destroy. Do not
proceed with a destroy that would touch a resource you did not expect
Terraform to manage.
