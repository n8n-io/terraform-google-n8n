# Troubleshooting

Issues observed in real deployments and how to resolve them. If you hit something not covered here, open an issue.

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
