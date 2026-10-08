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

### Offline license activation

If you deployed with `n8n_license_cert_secret_ref` instead of `n8n_license_key` or `n8n_license_key_secret_ref` (an air-gapped or egress-restricted cluster; see ["Offline license activation"](../README.md#offline-license-activation) in the root README), there is no key to paste in **Settings** > **License**: the certificate in your caller-managed Secret already activated the license as `N8N_LICENSE_CERT` at pod startup, with no round trip to n8n's license server. Confirm activation from **Settings** > **License**, or with `kubectl -n n8n exec deploy/n8n-main -- n8n license:info`. Rotating the certificate means updating the caller-managed Secret's payload and restarting the `n8n-main`, `n8n-worker`, and `n8n-webhook-processor` deployments, plus any `n8n-worker-<pool>` deployments from `n8n_worker_pools` (`kubectl -n n8n rollout restart deployment -l app.kubernetes.io/instance=n8n,app.kubernetes.io/component=worker-group`), since the module never reads the Secret's value and cannot detect a payload change itself.

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
