# Upgrading n8n

This guide covers behavior changes introduced by
`add-google-parity-through-aws-0-4-0` that affect an existing deployment:
GKE cluster replacement, resource-address changes that need a manual
`terraform state mv`, topology
transitions, newly reserved environment variable names, reference-only
configuration that needs a manual restart, corrected canonical URLs, Redis
prefix/persistence transitions, and the chart's existing replica-floor reset
behavior.

This module is pre-1.0 and, as stated in
[README.md, Stability & versioning](../README.md#stability--versioning), no
tagged version has shipped this interface yet: there is no automatic state
migration for any change below. Apply the manual steps in this guide yourself,
or start a fresh `terraform apply` against new state. See
[`versioning.md`](./versioning.md) for the full inventory of every provider,
chart, and CI-toolchain pin this module makes and which bump tier each falls
into.

## Moving from chart 1.13.0 to 1.14.0

The default `n8n_chart_version` moved from `1.13.0` to `1.14.0`
([n8n-hosting v1.14.0](https://github.com/n8n-io/n8n-hosting/releases/tag/v1.14.0)).
Check these points before you apply:

- **Pin the n8n version first if it is not already pinned.** With
  `n8n_image_tag = null`, the app moves with the chart's `appVersion`, from
  n8n `2.40.5` to `2.41.4`. n8n `2.41.0` through `2.41.4` list no breaking
  changes. Every n8n pod rolls once on the apply, because the image and the
  env list change.
- **n8n 2.0 or newer is required.** The chart no longer renders
  `N8N_AVAILABLE_BINARY_DATA_MODES`
  ([n8n-hosting#185](https://github.com/n8n-io/n8n-hosting/pull/185)), and
  the module stops sending `s3.storage.availableModes`. n8n 2.x ignores the
  variable, but n8n 1.x reads it and defaults to `filesystem` only, so a 1.x
  image would silently store binary data on each pod's own disk instead of
  the GCS bucket. This module does not support n8n 1.x. If you pin
  `n8n_image_tag` to a 1.x release, upgrade n8n to 2.x first (see the
  [n8n 2.0 migration guide](https://docs.n8n.io/2-0-breaking-changes/)).
- **`WEBHOOK_URL` is no longer sent to current images.** n8n `2.30.0`
  introduced `N8N_WEBHOOK_URL` and logs a deprecation warning while
  `WEBHOOK_URL` is set. The module now sends only `N8N_WEBHOOK_URL` when the
  image tags prove n8n `2.30.0` or newer, and keeps sending both names
  otherwise. See [Webhook URL](#webhook-url) for the exact rule.
- **Both deprecated names are now rejected with a deprecation error.**
  `n8n_extra_env`, `n8n_worker_extra_env`, and `n8n_worker_pools[*].extra_env`
  already rejected `N8N_AVAILABLE_BINARY_DATA_MODES` and `WEBHOOK_URL` as
  module-managed names. They now reject both through
  `local.n8n_deprecated_env_names`, with an error that says to remove the
  entry. No configuration that was accepted before is rejected now.
- **The chart's own webhook key changed name.** The chart's ConfigMap emits
  `N8N_WEBHOOK_URL` instead of `WEBHOOK_URL`
  ([n8n-hosting#184](https://github.com/n8n-io/n8n-hosting/pull/184), not in
  the upstream release notes). This has no effect here: the chart only emits
  it from its own `webhook.url` or `ingress` values, and the module sets
  neither.
- The worker, KEDA, and task-runner templates did not change, so
  `local.n8n_chart_has_worker_only_runners` (`capacity.tf`) now also covers
  `1.14.0`.

## GKE Dataplane V2 requires cluster replacement

**Breaking default, minor release only:** module-managed GKE now sets
`datapath_provider = "ADVANCED_DATAPATH"` (Dataplane V2). With Google provider
6.x, changing an existing cluster from `LEGACY_DATAPATH` forces cluster
replacement, not an in-place network upgrade. This default is intentional;
there is no module input to retain the legacy datapath on the managed path.
Clusters already using Dataplane V2 and customer-managed clusters
(`create_gke = false`) do not need replacement for this setting.

A replacement interrupts all workloads on that cluster, including the n8n
editor, API, webhooks, workers, and scheduled triggers. It also removes
cluster-local objects, including caller-managed Secrets and ConfigMaps. A
`terraform state mv` cannot avoid replacement: the resource address is not
the cause. Reverting the module version after deleting the old cluster does
not restore it.

Before upgrading an existing deployment:

1. Back up Terraform state, the n8n encryption key, the database, and any
   caller-managed Kubernetes objects or persistent data. Keep these backups
   secure and test recovery in a disposable environment.
2. Run `terraform plan` with the new module version. Inspect the cluster's
   `datapath_provider` diff and every replacement or deletion. Stop if the
   plan proposes replacing the VPC, Cloud SQL, Memorystore, or GCS resources
   you intend to retain. Do not use a full-stack destroy to migrate GKE.
3. Choose and rehearse a migration: provision a separate Dataplane V2 cluster
   and use the customer-managed-cluster contract, or accept a maintenance
   window for replacement. Do not run two independent n8n installations
   against the same live database and queue during a cutover.
4. For replacement, pause new executions and webhook traffic, then let queued
   and active jobs finish. While the old module version is still selected,
   apply `gke_deletion_protection = false` as a separate, reviewed change.
   Confirm this plan only removes cluster deletion protection. The default
   protection otherwise blocks deletion; do not disable database protection
   or set `gcs_force_destroy` for a cluster migration.
5. Follow the rehearsed cluster and workload migration procedure. Remove old
   Ingress resources while their controller still runs so load balancer
   cleanup can complete. Kubernetes, Helm, and kubectl providers depend on
   the cluster endpoint and CA, so do not assume one full-module apply can
   replace the cluster and reconcile all workloads. Reinitialize their
   connections to the new cluster and restore caller-managed objects before
   starting n8n.
6. Verify database and binary-storage access, credential decryption, worker
   execution, DNS/TLS, and every ingress route before resuming traffic.
   Restore `gke_deletion_protection = true` and confirm a final plan has no
   unexpected changes.

See [manual verification, item 13](./manual-verification-checklist.md#13-gke-dataplane-v2-migration)
for the required rehearsal evidence. No live cluster migration has been
validated by the mocked test suite.

## Resource-address changes

### Cloud DNS record: `count` to `for_each`

`n8n_additional_domains` (section 20.2) moved the canonical Cloud DNS A-record
(`google_dns_record_set.n8n`) from `count = var.cloud_dns_zone_name != null ? 1
: 0` to `for_each` keyed by hostname, so the canonical record keeps a stable
per-hostname address as aliases are added or removed. An existing deployment
that already applied with `cloud_dns_zone_name` set needs one manual move
before the next `apply`, or Terraform plans to destroy and re-create the
record:

```bash
terraform state mv \
  'module.n8n.google_dns_record_set.n8n[0]' \
  'module.n8n.google_dns_record_set.n8n["<your n8n_fqdn value>"]'
```

Substitute your module's local name if you call it something other than
`n8n`, and your actual `n8n_fqdn` value for the map key. Run `terraform plan`
afterward and confirm no DNS record changes are proposed. No other resource
addresses changed in this release.

## Topology transitions (single-main and multi-main)

Section 3 derives the initial main-pod count, once, from whichever scaler owns
it: `n8n_main_hpa_min_replicas` when `n8n_main_hpa_enabled = true` (the
default), otherwise `n8n_main_fixed_replicas`. A selected count of `1` is
**single-main** by default; any larger count keeps the module's **multi-main**
default. `n8n_main_leader_election_enabled` can override election independently:
`null` preserves this inference, `true` enables election even at one replica,
and `false` is rejected above one selected replica. At a selected count of one,
`Recreate`, PDB minimum 0, and the managed HPA maximum of 1 remain in effect
regardless of election mode.

Chart `1.10.1` rejects `multiMain.enabled = true` below two replicas. During
staging, that chart setting stays false and the module injects the literal
`N8N_MULTI_MAIN_SETUP_ENABLED=true` through `config.extraEnv` instead. That
list reaches main, worker, and webhook containers, so all three roles roll and
receive the flag. Verify non-main role health too. Above one replica, the module
removes this staging entry and uses the chart's normal main-only ConfigMap
reference. No chart validation is bypassed. Runtime election with one replica
and the supplied license must still be verified in the rehearsal.

### Moving to single-main

Set `n8n_main_hpa_min_replicas = 1` (HPA-owned) or `n8n_main_fixed_replicas =
1` (HPA disabled), with `n8n_main_leader_election_enabled = null`, then review
and apply the plan during a quiet maintenance window. This:

- Requires an n8n Enterprise license edition that supports single-main; it
  does not by itself grant External Secrets, log streaming, the custom
  package registry, or object-storage entitlements.
- Disables `multiMain`, clamps the main HPA's effective maximum to 1
  regardless of a higher configured `n8n_main_hpa_max_replicas`, switches the
  main Deployment's rollout `strategy` to `Recreate`, and relaxes the main
  PodDisruptionBudget to `minAvailable = 0`.
- Interrupts the editor, REST API, and scheduled triggers during any
  maintenance or rollout, since there is exactly one main pod and `Recreate`
  tears it down before starting the replacement. `Recreate` does not
  guarantee at-most-one execution after a manual pod deletion, node failure,
  or network partition either.
- A caller-owned main scaler (`n8n_main_hpa_enabled = false`) must not exceed
  one main while intentionally running single-main; only raise the fixed
  count when deliberately switching back to multi-main.

### Returning to multi-main

**Use two separate applies.** Raising replicas and enabling election in the
same apply can scale the old election-disabled ReplicaSet before replacing it.
Live testing observed two old single mains running concurrently and a new main
reporting three instances claiming leadership. Final-state health checks do
not detect this transition hazard. Setting `Recreate` alone does not order a
simultaneous replica increase against replacement.

Confirm the license supports multi-main, keep
`n8n_license_detach_floating_on_shutdown = false`, and rehearse the procedure
in a disposable environment first. Pause schedules, triggers, and new
submissions; let queued and active executions finish before starting. Keep the
same scaling owner throughout both stages and prevent any caller-owned scaler
from changing replicas. Pin application and runner images so this is not also
an image upgrade. Use an explicitly verified Kubernetes context and namespace
for every inspection.

1. **Enable election without increasing replicas.** Set these arguments on
   your existing module call for a managed HPA:

   ```hcl
   n8n_main_hpa_enabled             = true
   n8n_main_hpa_min_replicas        = 1
   n8n_main_leader_election_enabled = true
   ```

   For fixed replicas, keep `n8n_main_hpa_enabled = false` and
   `n8n_main_fixed_replicas = 1` instead. These are module arguments; an example
   root must explicitly forward the new input before it can be set in that
   example's `terraform.tfvars`.

   Review the plan: election changes, but the main replica count remains one,
   strategy remains `Recreate`, PDB minimum remains 0, and a managed main HPA
   remains min/max 1/1 even if its configured maximum is higher. Apply only
   this stage. Expect editor/API downtime; the environment changes also roll
   workers and webhook processors.

2. **Verify the intermediate state before proceeding.** Observe the rollout
   from before the apply. Confirm the old main process exits before its
   replacement starts, no election-disabled main remains (including terminating
   pods), and exactly one replacement main is Ready with
   `N8N_MULTI_MAIN_SETUP_ENABLED=true` in its running environment. Confirm
   license validity, election/leadership health, worker and webhook recovery,
   and successful queue execution. A plan with the stage-one settings must
   converge. Do not infer these facts solely from Helm values or exit status.

3. **Increase replicas in a separately reviewed apply.** Keep
   `n8n_main_leader_election_enabled = true` and raise the selected minimum or
   fixed count to two or more. This restores the chart-default main rollout
   strategy and PDB minimum 1; a managed HPA uses its configured maximum again.
   Confirm all surviving and newly started mains have election enabled, one
   leader is active, HTTPS and queue execution work, and the final plan has no
   unexpected changes before resuming production work.

The nullable default preserves compatibility; it does **not** enforce this
sequence. Terraform does not verify the previous pods' runtime state across
applies. Do not skip the intermediate verification, disable election while
scaling up, or use a stale plan from another stage. If either stage fails or
Helm rolls back, keep work paused, inspect the actual pod and election state,
and review a new recovery plan rather than automatically applying stage two.
Prefer recovery toward the verified election-enabled one-replica state, not the
original election-disabled revision. Rollback can also remove ConfigMap keys
still referenced by multi-main pods and prevent them from restarting; it is
not automatically safe or availability-preserving.

During stage three, expect Kubernetes to scale the *previous* ReplicaSet (the
stage-one template) to the new count first and then replace it with the new
template. Live testing observed this on both ownership paths. It is harmless
only because stage one already made that template election-enabled; it is the
same mechanism that made the one-step conversion unsafe.

On n8n 2.38.7, the main that takes over leadership at stage three logs
`EntityMetadataNotFoundError: No metadata for "Agent" was found` from
`AgentTaskService.reconnectAll`. The process keeps running and scheduling
continues, but treat it as an application issue to report upstream (it occurs
with the default module set: Instance AI enabled, Agents disabled). Do not
change `N8N_ENABLED_MODULES`/`N8N_DISABLED_MODULES` as an untested workaround.

The configuration and render tests cover these states, not transition timing
or duplicate scheduling. Live runs of the idle procedure passed on both
ownership paths; the active-schedule regression remains incomplete because of
the error above. See
[manual verification, item 2](./manual-verification-checklist.md#2-return-to-multi-main).

## Replica-floor reset on every Helm upgrade

This is existing chart behavior, not new in this release, but it interacts
directly with the topology transitions above: the module always renders an
unconditional `replicaCount` (the effective HPA minimum, or the fixed count)
for the main and webhook-processor Deployments, regardless of how many
replicas an HPA has actually scaled them to at apply time. Every `terraform
apply` that triggers a Helm upgrade of the n8n release resets main and
webhook-processor replicas back down to that floor, even if the HPA had
previously scaled them higher. An operator relying on HPA-scaled headroom
should not be surprised to see those two counts drop back to the configured
minimum immediately after any `apply` that touches the Helm release.

### Workers on chart 1.13.0 and later

Chart `1.13.0` ([n8n-hosting#201](https://github.com/n8n-io/n8n-hosting/pull/201))
stops rendering the **worker** Deployment's `replicas` field whenever
`keda.enabled` is on with triggers, which is this module's default
(`n8n_worker_keda_enabled = true`). From that chart on, a Helm upgrade no
longer touches the worker count at all: KEDA owns it, and
`n8n_worker_keda_min_replicas` is the floor KEDA enforces rather than a value
the chart re-stamps. The main and webhook-processor behavior above is
unchanged, because the chart only defers to an autoscaler it can see through
its own `hpa.*`/`keda.*` switches, and this module scales the webhook
processor with an external `HorizontalPodAutoscaler` (`scaling.tf`) instead.

**One-time effect on an existing release moved from chart `<= 1.12.0` to
`1.13.0` or later.** This only matters for a stack already applied from an
earlier commit of this unreleased module; a fresh apply is not affected.

- Helm removes the `replicas` field it used to manage, and Kubernetes resets
  the worker Deployment to `1` replica, whatever the configured floor.
- The HPA that KEDA manages behind the `ScaledObject` raises it back, on that
  controller's own schedule. It restores `n8n_worker_keda_min_replicas`, not
  the count running before the upgrade. KEDA scales higher only when the
  queue needs it.
- Surplus worker pods stop gracefully, but n8n itself waits only
  `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` (the chart's `redis.worker.timeout`, 30
  seconds by default, overridable via `n8n_graceful_shutdown_timeout`).
  Setting the value through `n8n_extra_env`, `n8n_worker_extra_env`, or a
  worker pool's `extra_env` is rejected at plan time: the chart always
  renders it on every n8n container, and `extraEnv` is appended after it, so
  a second entry with the same name would silently replace the chart's
  value. The pod is also bounded by `n8n_termination_grace_period`: the
  timeout plus `n8n_prestop_sleep` must stay below it. An explicit
  `n8n_graceful_shutdown_timeout` that does not fit fails validation. With
  the input unset, a chart default that does not fit only raises the
  `graceful_shutdown_fits_grace_period` plan-time warning. An execution
  still running after the timeout can be interrupted.
- Raising `n8n_worker_keda_min_replicas` first does not help. Upgrade in a
  low-traffic window and let running work drain first.

Later applies on the new chart have no such effect.

### Pausing worker autoscaling (chart 1.13.0 and later)

Pause needs chart `1.13.0` or newer. Charts before `1.12.0` ignore the key.
Chart `1.12.0` reads it but still sets the worker replica count on every Helm
upgrade, so a later apply while paused overrides the held count.
`check.worker_keda_pause_requires_a_supported_chart` warns at plan time for
an older chart from the default repository. This includes
`examples/worker-pools`' `1.11.0-preview.workerpools.1` pin. Only the default
worker Deployment is paused: `n8n_worker_pools` pools keep scaling on their
own `ScaledObject`s.

`n8n_worker_keda_pause = true` maps to the chart's `keda.worker.pause` and
annotates the worker `ScaledObject` with `autoscaling.keda.sh/paused=true`, so
KEDA stops reconciling and the workers hold their current count. Add
`n8n_worker_keda_paused_replica_count` to hold a specific count instead;
`0` scales the workers to zero while new jobs wait in Redis, for a
maintenance window or ahead of a database migration. Scaling to zero does
not wait for running executions: each worker gets only n8n's graceful
shutdown window (`N8N_GRACEFUL_SHUTDOWN_TIMEOUT`, 30 seconds by default,
overridable via `n8n_graceful_shutdown_timeout`) before it stops. So stop
new submissions and let active executions finish first, then pause at `0`,
migrate, and unpause. Anything still running when the workers stop can be
interrupted.
Setting `n8n_worker_keda_pause` back to `false` clears both annotations and
KEDA scales to the queue depth again on its next poll. The count is ignored
by the chart unless `pause` is true, and the module warns about that
combination at plan time. Webhook processors have no pause input: the module
scales them with its own HPA, not a chart `ScaledObject`, so the chart's
`keda.webhookProcessor.pause` has nothing to act on here. The same two
inputs exist under the same names in terraform-aws-n8n and
terraform-azurerm-n8n.

## Main pods lose the task-runner sidecar (chart 1.12.0 and later)

n8n-hosting [#179](https://github.com/n8n-io/n8n-hosting/pull/179), shipped
in chart `1.12.0` and unchanged through `1.14.0`, renders the task-runner
sidecar, its env, and the launcher ConfigMap mount on the main Deployment
only in standalone mode (`taskRunners.enabled && !queueMode.enabled`). This
module always runs queue mode, where n8n offloads manual executions to
workers and starts no runner broker on main, so from chart `1.12.0` on only
worker pods carry the `task-runner` container. Effects on an existing
deployment moving from `1.11.0` (this bump skips `1.12.0`, so a `1.11.0`
deployment takes both releases at once):

- Main pods roll once on the upgrade apply to drop the container (the same
  rollout that moves them to the new image); nothing to do.
- `n8n_task_runner_cpu_*`/`n8n_task_runner_memory_*`,
  `n8n_task_runner_custom_config`, and `n8n_task_runner_timeout` now apply
  to worker pods only, **while the pinned chart is one this module has
  verified carries the fix**: its own OCI repository
  (`oci://ghcr.io/n8n-io/n8n-helm-chart`) at version `1.12.0`, `1.13.0`, or `1.14.0`
  exactly (`local.n8n_chart_has_worker_only_runners` in `capacity.tf`). Any
  other `n8n_chart_version` (a private mirror, a preview build such as
  `examples/worker-pools`' `1.11.0-preview.workerpools.1`, which predates
  #179, or a future/older numbered release) keeps the conservative
  main-sidecar allowance in the capacity estimate, since the module has no
  way to see what an arbitrary pin's templates actually render.
- `tests/scripts/smoke-test.sh` checks the sidecar on a worker pod and
  reports one on main as a warning.

## License Secret delivery

Section 9 moved a directly supplied `n8n_license_key` from a literal
`license.activationKey` Helm value into a dedicated module-managed
`kubernetes_secret.n8n_license`, read via `license.existingSecret`. Callers
already using `n8n_license_key` or `n8n_license_key_secret_ref` need no
tfvars change; only the rendered Helm values differ (no literal license key
ever appears in them after this release). No license Secret is created, or
duplicated, when `n8n_license_key_secret_ref` is set instead.

## Exact-key encryption recovery

Section 8 added `n8n_encryption_key` (sensitive), letting you supply a known
64-hexadecimal-character key instead of letting the module generate one, most
importantly to keep decrypting existing credentials after restoring or
cloning onto a module-managed Cloud SQL instance. It is mutually exclusive
with `existing_n8n_core_secret_name`. If you already back up the
`n8n_encryption_key` output (see
[README.md, Out of scope](../README.md#out-of-scope) and
[destroy-cleanup.md](./destroy-cleanup.md#prerequisites)), you can now feed
that saved value back in via `n8n_encryption_key` on a restore or clone,
rather than losing decryption for existing credentials. See
[Restored/cloned database encryption-key continuity](./customer-managed-infrastructure.md#restoredcloned-database-encryption-key-continuity)
for the full restore/clone contract.

## New environment variable reservations

`n8n_extra_env` (and, for one entry, `n8n_extra_volumes`/
`n8n_extra_volume_mounts`) can no longer set the following names, because a
dedicated input now owns them; a value you previously passed through the
escape hatch is silently dropped from the plan (it fails Terraform validation
instead) until you move it to the dedicated input.

| Previously usable via `n8n_extra_env` | Reserved unconditionally or only while... | Dedicated input | Default |
| --- | --- | --- | --- |
| `N8N_WEBHOOK_URL` | unconditionally | `n8n_webhook_url` | `https://<n8n_fqdn>` |
| `EXECUTIONS_DATA_SAVE_ON_SUCCESS` | unconditionally | `n8n_executions_data_save_on_success` | `all` |
| `EXECUTIONS_DATA_SAVE_ON_ERROR` | unconditionally | `n8n_executions_data_save_on_error` | `all` |
| `EXECUTIONS_DATA_SAVE_ON_PROGRESS` | unconditionally | `n8n_executions_data_save_on_progress` | `false` |
| `EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS` | unconditionally | `n8n_executions_data_save_manual_executions` | `true` |
| `N8N_REDIS_KEY_PREFIX` | unconditionally | `redis_key_prefix` | `null` (n8n's own default) |
| `N8N_COMMUNITY_PACKAGES_REGISTRY` | unconditionally | `n8n_community_packages_registry` | `null` (n8n's own default) |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | unconditionally | `n8n_unverified_packages_enabled` | `null` (n8n's own default) |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | unconditionally | `n8n_compression_max_decompressed_size_bytes` | `null` (n8n's own default) |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | unconditionally | `n8n_compression_max_zip_entries` | `null` (n8n's own default) |
| `CREDENTIALS_OVERWRITE_DATA`, `CREDENTIALS_OVERWRITE_DATA_FILE` | only while `n8n_credentials_overwrite_secret_ref` is non-null | `n8n_credentials_overwrite_secret_ref` | `null` (escape hatch usable again once unset) |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | unconditionally | `n8n_graceful_shutdown_timeout` | `null` (chart's own 30s default) |

`N8N_EDITOR_BASE_URL` was already reserved before this release, but the
module never actually set it; see
[Separate editor and webhook hosts](#separate-editor-and-webhook-hosts) below
for what changes now that it is set on every apply.

`db_ping_*`, `db_postgresdb_connection_timeout_ms` (section 4), and the
`n8n_queue_worker_*` settings (section 5) use the pre-existing `DB_*`/`QUEUE_*`
prefix reservations, already blocked before this release; no migration is
needed for those two families specifically.

## Reference-only configuration changes

Two new inputs pass a Kubernetes object *reference* through to the chart
without the module reading, hashing, or diffing its contents. Changing only
the referenced object's data, not the reference itself, gives Terraform
nothing to diff, so no automatic rollout happens:

- **`n8n_credentials_overwrite_secret_ref`** (section 11): after rotating the
  referenced Secret's data, manually restart all three n8n deployments. See
  [troubleshooting.md, Credential-overwrite Secret content changes need a manual restart](./troubleshooting.md#credential-overwrite-secret-content-changes-need-a-manual-restart).
- **`n8n_task_runner_custom_config`** (section 12): after changing the
  referenced ConfigMap's data, manually restart `n8n-main` and `n8n-worker`.
  See
  [troubleshooting.md, Task-runner custom launcher configuration needs a matching image and a manual restart](./troubleshooting.md#task-runner-custom-launcher-configuration-needs-a-matching-image-and-a-manual-restart).

## Corrected canonical URLs

### Separate editor and webhook hosts

Section 19 sets `N8N_EDITOR_BASE_URL=https://<n8n_fqdn>` on every n8n role.
This name was already reserved against `n8n_extra_env` before this release
but never actually set, leaving n8n to compute its own editor/OAuth base URL
internally. If you run a split-host deployment (a separate webhook host via
`n8n_webhook_url`) and any OAuth2 credential's redirect URI was registered
against n8n's previously self-computed URL rather than
`https://<n8n_fqdn>/rest/oauth2-credential/callback`, re-register that
redirect URI with the OAuth provider using `n8n_fqdn` as the callback host
before or immediately after this upgrade.

### Webhook URL

`n8n_webhook_url` (default `https://<n8n_fqdn>`) is emitted as
`N8N_WEBHOOK_URL`. The legacy `WEBHOOK_URL` gets the same value, so the two
can never drift apart, but only when the image may predate n8n `2.30.0`, the
first release that reads `N8N_WEBHOOK_URL`. Without `WEBHOOK_URL`, an older
image falls back to `http://<n8n_fqdn>:5678/` in every webhook URL, while a
current image only logs a deprecation warning when it is set. So the module
drops `WEBHOOK_URL` only when the tags prove the image is current
(`local.n8n_needs_legacy_webhook_url_env`):

- `n8n_image_tag` starts with a full `MAJOR.MINOR.PATCH` version of
  `2.30.0` or newer (for example `2.41.4` or `2.41.4-mypackages`). A tag
  such as `2.30.mypackages` has no numeric patch and proves nothing.
- `n8n_image_tag` is a custom image tag with no version, task runners are
  enabled, and `n8n_task_runner_image_tag` is `2.30.0` or newer.
- `n8n_image_tag` is null, on the default chart repository, at chart
  `1.12.0` or newer, whose `appVersion` is a concrete `2.39.6` or newer.

Floating tags (`stable`, `latest`), a null tag on a private chart mirror or
on a chart before `1.12.0`, and a custom image whose tags carry no version
still get `WEBHOOK_URL` and its warning. Pin a versioned `n8n_image_tag` to
remove it.
`n8n_webhook_url` also now validates as an `https://` base URL with no
embedded userinfo credentials, query string, or fragment; a previously
accepted value that violated any of those now fails `terraform plan`.

## Redis transitions

### Command-channel and Bull prefix isolation

Section 7 wires `redis_key_prefix` into n8n's command channel
(`N8N_REDIS_KEY_PREFIX`) in addition to the Bull queue-key prefix
(`redis.prefix`, already wired before this release). Both settings now always
move together. If you already set `redis_key_prefix` on a live deployment,
the next `apply` changes n8n's command-channel prefix for the first time;
treat it the same as any other prefix change, see
[Disruptive Redis transitions](./customer-managed-infrastructure.md#disruptive-redis-transitions):
drain the queue first, and let the Helm upgrade restart all three deployments
together rather than rolling them independently, since a partial rollout
would split main/worker communication across two command-channel namespaces.

### Opt-in Memorystore RDB persistence

Section 18 added `redis_persistence_enabled` (default `false`, opt-in) plus
`redis_rdb_snapshot_period`/`redis_rdb_snapshot_start_time`. Enabling this on
an existing module-managed instance is additive infrastructure, not a
migration hazard, but see
[post-deployment.md, Redis persistence and recovery](./post-deployment.md#redis-persistence-and-recovery)
before enabling it: it is Memorystore's own automatic last-snapshot recovery
on an unplanned restart, not a numbered backup-retention count, and can
reintroduce stale or duplicate queued jobs.

Setting `redis_persistence_enabled = false` explicitly configures
`persistence_mode = "DISABLED"`, including after RDB was enabled. It no longer
omits the provider's optional/computed block, which retained the previous
RDB setting. An instance still using RDB while this input is false will now
plan an update to disable it. Review this change before applying if you rely
on snapshot recovery. Snapshot schedule inputs are omitted while disabled;
reset them to their defaults to clear ignored-input warnings. To re-enable,
set the switch to true and review the desired schedule again.

### Memorystore maxmemory-policy now defaults to noeviction

`redis_maxmemory_policy` (default `"noeviction"`) now wires
`redis_configs["maxmemory-policy"]` into the module-managed Memorystore
instance. Memorystore's own unconfigured default is `volatile-lru`, which
evicts keys that carry a TTL once the instance is full. Bull's queued jobs
have no TTL, but its per-job lock keys do. Evicting a lock can cause Bull
to detect an active job as stalled. Because n8n sets `maxStalledCount: 0`,
the first detected stall fails the job instead of retrying it.
`noeviction` instead rejects writes once the instance is full, so the
failure shows up as a Redis error.

This is an in-place Memorystore configuration update. No instance restart
is required. It does change behavior at capacity: write errors appear
where evictions happened before. Before the next `apply`:

- Check the instance's current policy, for example with
  `gcloud redis instances describe <name> --region <region>
  --format='value(redisConfigs)'`. No `maxmemory-policy` in the output
  means the instance uses Memorystore's default, `volatile-lru`. If someone
  set `maxmemory-policy` outside Terraform, the next `apply` overwrites it.
  Set `redis_maxmemory_policy` to that value to keep it.
- Review the whole `redis_configs` change in the plan, not just
  `maxmemory-policy`. The provider sends only the configured map and does
  not merge in other keys set outside Terraform.
- Set `redis_maxmemory_policy = "volatile-lru"` to keep Memorystore's
  previous default.
- If you relied on eviction to stay under capacity, review the memory
  headroom (`redis_memory_size_gb`).

`volatile-lfu` and `allkeys-lfu` need Redis 4.0 or later. The module
rejects them at plan time when `redis_version = "REDIS_3_2"`.

Rolling back to a module version without `redis_maxmemory_policy` is also
an in-place update with no instance restart. Terraform removes the
`maxmemory-policy` key, and Memorystore immediately resets the policy to
its default, `volatile-lru`. The previous value does not stay in place.
This was observed on a BASIC tier instance running Redis 7.2.

## Sizing and observability additions

Sections 16 and 17 add an opt-in private Redis exporter
(`redis_exporter_enabled`) and Cloud SQL backup/log tuning
(`postgres_backup_retained_backups`,
`postgres_transaction_log_retention_days`, `postgres_query_logging_enabled`).
All default to their prior effective behavior (exporter off, backup/log
settings at the provider's existing defaults) and require no action on an
existing deployment; enabling the exporter adds fixed CPU/memory requests to
the managed GKE capacity guardrail (`capacity.tf`), so re-run `terraform plan`
to confirm your node pool still has headroom before enabling it on a
capacity-constrained cluster.

## Caller-owned ingress

If you run `create_ingress = false` with your own Ingress resource (see
[`examples/split-ingress`](../examples/split-ingress/)), no wiring in this
module changed the routes you already own. `n8n_additional_domains` and
`ingress_annotations` (sections 20.1-20.3) only affect the module-managed
Ingress; a caller-owned Ingress can still read the same effective hostname
list from the `n8n_ingress_hosts` output if useful, but nothing requires it
to.

## Terraform CLI floor raised to >= 1.11

**Breaking, every caller of the root module:** `required_version` is now
`>= 1.11` (was `>= 1.9`), and the `google`/`google-beta` provider floors
are now `~> 6.23` (was `~> 6.0` in 0.1.0). The new opt-in
`postgres_password_write_only` (see `cloudsql.tf` and the "Cloud SQL
PostgreSQL" section of `variables.tf`) needs them: an `ephemeral = true`
variable (`postgres_password_wo`) needs Terraform 1.10's ephemeral-value
support, feeding it into `google_sql_user.n8n`'s `password_wo` argument
needs 1.11's write-only-argument support for managed resources, and
`google_sql_user.password_wo`/`password_wo_version` need `google` provider
`>= 6.23.0` (this also covers the GKE Secret Manager add-on's need for
6.1, see `CHANGELOG.md`). `google-beta` uses no write-only argument; it
moves only because the module keeps it in lockstep with `google`
(`docs/versioning.md`). Terraform parses these floors from this module's
HCL unconditionally, so they apply to every caller regardless of whether
`postgres_password_write_only` is set. The `modules/controllers` submodule
does not use either feature and keeps its own floors.

Upgrade the Terraform CLI and run `terraform init -upgrade` so the
`google`/`google-beta` providers resolve within the new range before
running `terraform plan` against this module version. An older CLI fails
at parse time on the unsupported `ephemeral = true` argument, before any
resource is evaluated. If your root module pins either Google provider
below 6.23, widen that constraint first. No state migration is required for
this change by itself: the floor bump alone does not change any resource's
planned attributes.

## Opt-in: `postgres_password_write_only`

New, fully opt-in (default `false`, no plan diff for existing callers).
Setting `postgres_password_write_only = true` (with
`create_postgres_instance = true`) writes the Cloud SQL user's password
through `google_sql_user.n8n`'s write-only `password_wo` argument instead of
generating one with `random_password.db_password` and storing it in plain
text in Terraform state. Feed the actual value through
`postgres_password_wo` and increment `postgres_password_wo_version`
whenever you rotate it; Terraform only re-applies a write-only value when
its version number changes. Empty or whitespace-only values are rejected.

`postgres_password_wo` is an `ephemeral` module variable, so this module
never writes the value to a plan or state file. That holds end to end only
if your root module passes an ephemeral value too, such as an ephemeral
input variable or an ephemeral resource that reads a Secret Manager secret
version. An ordinary root input variable is saved in your plan file, and an
ordinary data source stores the secret in your state. Ephemeral values are
not saved in a plan file either, so when you apply a saved plan, supply the
same value again.

Because the value never touches state, the module also cannot copy it into
the Kubernetes Secret it would otherwise manage (`kubernetes_secret.n8n_db`,
in `n8n.tf`): the `kubernetes` provider's write-only `data_wo` support
exists only on `kubernetes_secret_v1`, and this module still uses the
unversioned `kubernetes_secret` type for its other managed Secrets (see
`CHANGELOG.md`, Known limitations, on why). Enabling
`postgres_password_write_only` therefore also requires
`n8n_database_password_secret_ref`, under a name other than
`n8n-enterprise-db-secret`. That name belongs to `kubernetes_secret.n8n_db`,
which this mode deletes, so a validation rejects it. Populate that Secret
yourself, outside Terraform, with the same password you passed to `postgres_password_wo`,
for example synced from Google Secret Manager with External Secrets
Operator. The GKE Secret Manager add-on (`gke_secret_manager_addon_enabled`)
does not work for this: it mounts secrets as files and does not sync them
into a Kubernetes Secret. The module never reads that
Secret's value, so nothing checks the two stay in sync; a mismatch surfaces
as a PostgreSQL authentication failure on the next pod restart, not a
Terraform error. The `n8n_database_password` output is `null` on this path
for the same reason.

### Switching an existing deployment to the write-only password

On an existing deployment, one apply that sets
`postgres_password_write_only = true` does three things:

- It updates `google_sql_user.n8n` from `password` to `password_wo`. The
  provider sends this as a password change on the existing user, not a
  replacement.
- It destroys `random_password.db_password[0]` and
  `kubernetes_secret.n8n_db[0]`.
- After the user update, it points the Helm release at the Secret named by
  `n8n_database_password_secret_ref` (`helm_release.n8n` depends on
  `google_sql_user.n8n`). The pod template changes, so the n8n pods roll
  during the same apply. The release uses `wait` and `atomic`, so if the
  new pods cannot start (for example, the Secret does not exist yet) Helm
  rolls the release back to the deleted `n8n-enterprise-db-secret`, but the
  Cloud SQL password change is not rolled back. Neither a Helm rollback
  nor restoring an older state file restores the database password.

To switch without a credential change during the switch, do it in two steps:

1. Read the current password with
   `terraform output -raw n8n_database_password`. Create a new Secret in the
   n8n namespace with that value, under the name and key you will pass in
   `n8n_database_password_secret_ref`. Do not reuse
   `n8n-enterprise-db-secret`.
2. Set `postgres_password_write_only = true`,
   `n8n_database_password_secret_ref`, and `postgres_password_wo` to that
   same current password, then apply. The pods roll onto your Secret, and
   the database password does not change.
3. Rotate. Earlier state snapshots and saved plan files still hold the old
   `random_password` result, so the password is not out of state until you
   change it. Follow the rotation steps below.

### Rotating the write-only password

1. Set `postgres_password_wo` to the new password and increment
   `postgres_password_wo_version`, then apply. Terraform sends the new
   value only when the version changes.
2. Update the Secret named by `n8n_database_password_secret_ref` to the
   same value.
3. Restart the `n8n-main`, `n8n-worker`, and `n8n-webhook-processor`
   deployments (and any `n8n_worker_pools` deployments) so they read the
   new value.

PostgreSQL keeps sessions that are already open after a password change,
but new connections fail between step 1 and step 3. Do this in a
maintenance window, or keep the steps close together.

### Switching back to the generated password

Set `postgres_password_write_only = false` and remove
`postgres_password_wo` and `n8n_database_password_secret_ref` (on the
module-managed path, a leftover `n8n_database_password_secret_ref` is
ignored with a warning). The next apply generates a new
`random_password.db_password`, sends it as the user's password, creates
`kubernetes_secret.n8n_db` with it, and points the Helm release back at
that Secret, so the pods roll onto the new password in the same apply.
This is a rotation, and the new password is stored in state again.
`helm_release.n8n` depends on `google_sql_user.n8n`, so the pods roll only
after the database accepts the new password, but sessions that n8n opens
with the old password after that point fail until the rollout finishes.
Do this in a maintenance window.

Keep the Secret you managed until the rollout has finished and n8n is
healthy. If the apply fails after the user update (for example, the Helm
release times out and rolls back to your Secret), the database already has
the new generated password. The module has already written it to
`n8n-enterprise-db-secret` (the Helm release references that Secret, so
Terraform creates it first). Either fix the cause and apply again, or copy
the value from `n8n-enterprise-db-secret` into your Secret and restart the
n8n deployments. Delete
your Secret only after a successful apply.
