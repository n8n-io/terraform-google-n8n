# Destroy & cleanup guide

This guide covers how to cleanly tear down the n8n infrastructure and troubleshoot the issues that most commonly arise during `terraform destroy` on Google Cloud.

## Customer-managed layers

On a mixed-ownership deployment (any `create_*` switch set to `false`), Terraform never destroys the resource you own: an existing network, GKE cluster, PostgreSQL database, Redis instance, GCS bucket, namespace, KEDA installation, or Cloud KMS key. Run `terraform plan -destroy` first and confirm it lists only module-owned resources before proceeding; see [`customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#customer-managed-resource-teardown-boundary) for the full contract.

## Prerequisites

Before destroying, back up the following from `terraform output`:

```bash
terraform output -raw n8n_encryption_key     # Save to a password manager
terraform output -raw n8n_database_password  # Save to a password manager
```

`n8n_encryption_key` reflects whichever value is effective, whether the
module generated it or you supplied it directly via `n8n_encryption_key`; see
[`docs/upgrading-n8n.md`](./upgrading-n8n.md#exact-key-encryption-recovery) for
reusing a saved key on a restore or clone.

Set shell variables used throughout this guide:

```bash
PROJECT=$(gcloud config get-value project)
CLUSTER=$(terraform output -raw gke_cluster_name)
REGION=$(terraform output -raw gcp_region 2>/dev/null || echo us-east4)
NS=$(terraform output -raw n8n_kube_namespace)
```

## Deletion protection

Cloud SQL and the GKE cluster ship with deletion protection on by default, and the provider reads that flag from the live resource, not from a var passed only to `destroy`. So flip the flags with an `apply` first, then destroy:

```bash
terraform apply -auto-approve \
  -var gke_deletion_protection=false \
  -var postgres_deletion_protection=false \
  -var gcs_force_destroy=true

terraform destroy -auto-approve \
  -var gke_deletion_protection=false \
  -var postgres_deletion_protection=false \
  -var gcs_force_destroy=true
```

The module's dependency graph then destroys resources in the correct order:

1. Ingress (the L7 load balancer begins deprovisioning)
2. A short pause for load balancer resource release
3. n8n Helm release
4. Namespace
5. KEDA
6. GKE node pool and cluster
7. Cloud SQL, Memorystore, GCS
8. A pause for Private Service Access release, then the PSA connection, address, and VPC

Most destroys complete in 10 to 20 minutes without intervention.

### Module-created CMEK keys (`create_postgres_kms_key`, `create_redis_kms_key`, `create_gcs_kms_key`)

Module-created Cloud KMS CryptoKeys carry `lifecycle { prevent_destroy = true }`: losing a CMEK key makes the data it protects unrecoverable, so Terraform refuses any plan that would destroy one. This blocks two situations:

1. **Flipping a `create_*_kms_key` switch from `true` back to `false`.** The plan wants to destroy the key and fails. Back out deliberately: first migrate the protected service off the key (for Cloud SQL and Memorystore that means recreating the instance, since neither supports changing CMEK in place), then remove the key from state instead of destroying it:

   ```bash
   terraform state rm 'module.n8n.google_kms_crypto_key.postgres[0]'   # or .redis[0] / .gcs[0]
   ```

   The key stays in Cloud KMS (a destroyed CryptoKey cannot be re-created under the same name anyway; KMS key material is only ever scheduled for destruction). Schedule its versions for destruction out of band with `gcloud kms keys versions destroy` once nothing encrypted with it must remain readable.

2. **A full `terraform destroy` of a deployment that used a module-created key.** Remove the key (and, if module-created, the key ring) from state first, then destroy the rest:

   ```bash
   terraform state rm 'module.n8n.google_kms_crypto_key.postgres[0]' 'module.n8n.google_kms_key_ring.n8n[0]'
   terraform destroy ...
   ```

## Troubleshooting

### Private Service Access peering is abandoned, not deleted

`terraform destroy` does not delete `google_service_networking_connection.psa` through the servicenetworking API; the resource sets `deletion_policy = "ABANDON"`, so Terraform drops it from state and moves on.

**Why:** that API enforces a producer-side check that fails with `Producer services (e.g. CloudSQL, Cloud Memstore, etc.) are still using this connection` for anywhere from a few minutes to several days after the Cloud SQL and Memorystore instances are actually gone. Google exposes no signal for when the release completes, so no destroy-time pause or retry can make the delete reliable.

**What happens instead:**

- `create_network = true` (default): Terraform deletes the PSA address range, then the VPC. Deleting a VPC tears down its `servicenetworking-googleapis-com` peering at the compute layer, which is not subject to the producer check. Nothing is left behind.
- `create_network = false`: the peering stays on your VPC, which the module does not own. If no other producer (another Cloud SQL or Memorystore instance) still uses that network, remove it yourself once GCP's release has caught up:

  ```bash
  gcloud compute networks peerings delete servicenetworking-googleapis-com \
    --network="<your-network>" \
    --project="$PROJECT"
  ```

  The reserved PSA address range (`google_compute_global_address.psa`) is still module-owned and deleted normally on this path.

### Namespace stuck in Terminating

**Symptom:** the namespace stays in `Terminating` for more than a couple of minutes, or `kubernetes_namespace.n8n` hangs on destroy.

**Cause:** orphaned custom resources (e.g. KEDA ScaledObjects) with finalizers from controllers that have already been uninstalled.

**Fix:** strip finalizers from the remaining resources in the namespace:

```bash
kubectl api-resources --verbs=list --namespaced -o name | while read RESOURCE; do
  kubectl get "$RESOURCE" -n "$NS" \
    -o jsonpath='{range .items[?(@.metadata.finalizers)]}{@.kind}/{@.metadata.name}{"\n"}{end}' \
    2>/dev/null | while read OBJ; do
    [ -n "$OBJ" ] || continue
    NAME=$(echo "$OBJ" | cut -d/ -f2)
    kubectl patch "$RESOURCE/$NAME" -n "$NS" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done
```

If the cluster itself is already being destroyed, the namespace object is going away with it; in that case remove it from state (below) rather than waiting on the Kubernetes API.

### GCS bucket delete fails because it is not empty

**Symptom:** `terraform destroy` fails to delete `google_storage_bucket.n8n` because it still contains n8n binary data.

**Fix:** destroy with `-var gcs_force_destroy=true` (shown above), which lets Terraform delete the bucket and its contents.

### Removing stuck resources from Terraform state

If a resource was already deleted outside Terraform (e.g. a namespace force-deleted via `kubectl`, or a peering removed with `gcloud`) and Terraform cannot refresh it:

```bash
# List all resources in state
terraform state list

# Remove a specific resource from state (does NOT delete the actual resource)
terraform state rm <resource_address>

# Example: remove a namespace that was force-deleted via kubectl
terraform state rm module.n8n.kubernetes_namespace.n8n
```

After removing the resource from state, re-run `terraform destroy` for the remaining resources.
