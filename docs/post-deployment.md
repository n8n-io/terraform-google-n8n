# Post-deployment setup

After `terraform apply` completes, finish setup by pointing your domain at n8n and activating your n8n Enterprise license.

## Wait for the load balancer and certificate

The Google Cloud L7 load balancer is provisioned asynchronously after the Ingress resource is created. Allow a few minutes after apply for it to become reachable, and, with `tls_mode = "google_managed"`, a further few minutes for the ManagedCertificate to move to `Active`. Verify:

```bash
terraform refresh
terraform output -raw static_ip
kubectl get ingress n8n-ingress -n n8n
kubectl get managedcertificate -n n8n   # only for tls_mode = "google_managed"
```

## Point your domain at n8n

**If you used `cloud_dns_zone_name`:** nothing to do, the A-record was created during apply. Verify propagation:

```bash
dig +short n8n.yourdomain.com
```

**If you manage DNS yourself:** create an A-record pointing at the load balancer IP.

| Type | Name                      | Value                                      | TTL |
| ---- | ------------------------- | ------------------------------------------ | --- |
| A    | `n8n` (or your subdomain) | IP from `terraform output -raw static_ip`  | 300 |

With `tls_mode = "google_managed"`, the certificate cannot provision until this record resolves to the load balancer IP, so create it promptly after apply.

## Access n8n and activate your license

Open `https://n8n.yourdomain.com` in your browser. Create your owner account, then select **Settings** > **License** and enter your activation key.

## Redis persistence and recovery

`redis_persistence_enabled` (default `false`) turns on Memorystore's own RDB
persistence for a module-managed instance. This is **not** a backup feature
and is not comparable to `postgres_backup_retained_backups`/point-in-time
recovery on Cloud SQL, or to AWS ElastiCache's numbered snapshot retention:

- Memorystore keeps **at most one** RDB snapshot, taken on the schedule set by
  `redis_rdb_snapshot_period` (`ONE_HOUR`, `SIX_HOURS`, `TWELVE_HOURS`, or
  `TWENTY_FOUR_HOURS`; default `TWENTY_FOUR_HOURS`) and optionally aligned to
  `redis_rdb_snapshot_start_time`. There is no history of restore points, and
  no way to pick an older snapshot once a newer one is written.
- Recovery only happens automatically, on an unplanned Memorystore restart
  (for example a failover or maintenance event); it replays the last snapshot
  rather than restoring current state. Any queue or Bull key writes since that
  snapshot are lost, and n8n's workers may see **stale or duplicate** queued
  jobs replayed from before the restart. Treat this the same way you would a
  crash-recovery journal, not a checkpoint you can restore to on demand.
- Snapshotting adds memory overhead (Redis forks to write the RDB file) and a
  latency spike while the snapshot is taken, which is more noticeable on
  smaller `redis_memory_size_gb` instances or `BASIC` tier without a replica.
  Weigh this against your actual recovery requirement before enabling it.
- This module does not schedule, export, or import Redis backups.
  Independent backup/export of Memorystore data (for example scheduled
  `gcloud redis instances export` runs to Cloud Storage) remains an operator
  responsibility outside this module.

To turn persistence off again, set `redis_persistence_enabled = false`,
review the plan, and apply it. The module explicitly sends `DISABLED`, rather
than omitting the configuration and retaining an existing RDB setting. This
removes the automatic snapshot-recovery protection. Reset schedule inputs
to their defaults while disabled to avoid ignored-input warnings.

`redis_persistence_enabled`, `redis_rdb_snapshot_period`, and
`redis_rdb_snapshot_start_time` are ignored for external Redis
(`create_redis_instance = false`); the module warns instead of failing if any
are left set. The two schedule inputs are also ignored, with a warning, when
`redis_persistence_enabled = false` on a module-managed instance.

## Private control-plane endpoint reachability

If `gke_enable_private_endpoint = true`, the GKE control plane no longer
accepts client traffic on its public endpoint. `kubectl` and the
`kubernetes`/`helm` providers can only reach it from inside the VPC
(directly, peered, or via VPN/Cloud Interconnect), and only from the same
region as `gcp_region` unless the cluster's `master_global_access_config` is
enabled out of band. Confirm reachability from your apply host before
troubleshooting an unrelated failure:

```bash
terraform output -raw gke_cluster_endpoint   # must resolve to an internal (RFC 1918) IP
kubectl cluster-info                          # hangs/times out from outside the VPC; succeeds from a bastion/VPN-connected host
```

See [`docs/troubleshooting.md`](./troubleshooting.md) if the cluster is
unreachable after enabling this.

### Switching an existing deployment to the private endpoint

`enable_private_endpoint` updates the cluster in place; it does not replace
it. But the `kubernetes`, `helm`, and `kubectl` providers in the same root
module are configured from `gke_cluster_endpoint`, which still holds the
public address when the cutover run starts. Depending on how you run the
apply, they can keep using that address for the rest of the run, so a
Kubernetes or Helm change that runs after the cluster update can fail to
connect. Keep the cutover to the cluster update alone. To switch:

1. Set up the private connectivity first, in the same region as
   `gcp_region`: a bastion VM in the VPC, a VPN or Interconnect-connected
   network, or a Cloud Build private pool with verified routing to the
   control plane (VPC peering alone is not transitive).
2. From your current admin host, add that network's internal CIDR to
   `gke_control_plane_authorized_networks` and apply. Keep your current
   public admin CIDRs in the list for now, and also add the public egress
   address of the private host (for example its Cloud NAT address): the
   cutover plan still talks to the public endpoint.
3. From the private host, confirm it reaches the private endpoint before you
   cut over:

   ```bash
   gcloud container clusters get-credentials <cluster> --region <gcp_region> --project <project> --internal-ip
   kubectl get namespaces
   ```

4. From the private host, in one change, set
   `gke_enable_private_endpoint = true` and remove every public CIDR from
   `gke_control_plane_authorized_networks` (validation accepts only RFC 1918
   entries in this mode). The google provider sends both settings in one
   control-plane update request. Save the plan with `terraform plan -out=private.tfplan`,
   check that it shows only an in-place update to
   `google_container_cluster.n8n`, then run `terraform apply private.tfplan`.
5. Re-run the `kubectl_config_command` output. In this mode it passes
   `--internal-ip`, so `kubectl` uses the private endpoint. The next plan
   configures the providers with the private address.

To go back, set `gke_enable_private_endpoint = false` and add your public
admin CIDRs back to `gke_control_plane_authorized_networks` in the same
change, then apply from the private host. Turning the flag off alone restores
the public endpoint in place but still rejects every public source address
that is not in the list.
