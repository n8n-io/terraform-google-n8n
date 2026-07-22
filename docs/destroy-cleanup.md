# Destroy & cleanup guide

This guide covers how to cleanly tear down the n8n infrastructure and troubleshoot the issues that most commonly arise during `terraform destroy` on Google Cloud.

## Prerequisites

Before destroying, back up the following from `terraform output`:

```bash
terraform output -raw n8n_encryption_key   # Save to a password manager
terraform output -raw db_password           # Save to a password manager
```

Set shell variables used throughout this guide:

```bash
PROJECT=$(gcloud config get-value project)
CLUSTER=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw gcp_region 2>/dev/null || echo us-east4)
NS=$(terraform output -raw namespace)
```

## Deletion protection

Cloud SQL and the GKE cluster ship with deletion protection on by default, and the provider reads that flag from the live resource, not from a var passed only to `destroy`. So flip the flags with an `apply` first, then destroy:

```bash
terraform apply -auto-approve \
  -var cluster_deletion_protection=false \
  -var cloudsql_deletion_protection=false \
  -var gcs_force_destroy=true

terraform destroy -auto-approve \
  -var cluster_deletion_protection=false \
  -var cloudsql_deletion_protection=false \
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

## Troubleshooting

### Private Service Access peering deletion stalls

**Symptom:** `terraform destroy` fails on `google_service_networking_connection.psa` with:

```
Error: Unable to remove Service Networking Connection ... Producer services
(e.g. CloudSQL, Cloud Memstore, etc.) are still using this connection.
```

**Cause:** Cloud SQL and Memorystore report deletion complete before Google's backend finishes releasing their hold on the PSA peering. The lag is not fixed and has been observed from a few minutes to well over an hour, and Google exposes no signal for when it completes.

**Built-in mitigation:** the module pauses on destroy (`time_sleep.wait_for_psa_cleanup`) between deleting Cloud SQL / Memorystore and deleting the peering. Raise the pause if your teardowns still stall:

```bash
terraform destroy -auto-approve \
  -var cluster_deletion_protection=false \
  -var cloudsql_deletion_protection=false \
  -var gcs_force_destroy=true \
  -var psa_cleanup_destroy_duration=15m
```

**Escape hatch (reliable):** if a teardown is already blocked, delete the peering at the compute layer, then re-run destroy:

```bash
gcloud compute networks peerings delete servicenetworking-googleapis-com \
  --network="${CLUSTER}-vpc" \
  --project="$PROJECT"

terraform destroy -auto-approve \
  -var cluster_deletion_protection=false \
  -var cloudsql_deletion_protection=false \
  -var gcs_force_destroy=true
```

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
