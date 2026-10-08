# Customer-managed infrastructure guide

This module can create its entire stack, or let a platform team bring any
combination of network, GKE cluster, PostgreSQL, Redis, GCS bucket,
Kubernetes namespace, secrets, ingress, and application autoscaling. Every
layer has its own static `create_*` (or `install_*`) ownership switch, plus
typed inputs for referencing the existing resource when the switch is
`false`. This guide is the single place that documents, per layer:

- exactly which resources the module omits when you own that layer,
- which resources and permissions the module still creates around it,
- the required references and prerequisite attestations,
- the security boundary the module observes, and
- the effective, ownership-neutral outputs your own tooling should consume.

See [`examples/customer-managed-cluster`](../examples/customer-managed-cluster),
[`examples/customer-managed-redis`](../examples/customer-managed-redis),
[`examples/customer-managed-gcs`](../examples/customer-managed-gcs), and
[`examples/customer-managed-everything`](../examples/customer-managed-everything)
for runnable compositions of the patterns below.

## Ownership model

Every ownership switch is a static, non-null `bool` (never inferred from
whether a reference is set), because Terraform `count` expressions cannot
depend on values only known after apply. Set the switch to `false` and supply
the paired reference input(s); leave it `true` (the default for every layer
except KMS keys) to let the module manage that layer itself.

The module never reads the contents of a Secret it does not manage, and never
mutates or deletes a resource it does not own. Where the module cannot safely
observe a property of an existing resource (permissions, reachability,
capacity, controllers already installed), it requires an explicit
`*_prerequisites_attestation` boolean instead of silently trusting or
refusing to proceed. Getting an attestation wrong produces resource errors at
apply time or a broken runtime, not corrupted or deleted infrastructure,
because the module still does not touch resources it does not own.

## Ownership matrix

| Layer | Switch | `false` requires | Module still creates around it |
| --- | --- | --- | --- |
| Network / PSA | `create_network`, `create_psa` | `existing_network_name`, `existing_subnetwork_name`, `existing_pods_range_name`, `existing_services_range_name` (network); `existing_psa_prerequisites_attestation` (PSA, only if a managed data service also needs it) | Nothing network-level; GKE and managed data services attach to the effective network/subnet/range IDs |
| GKE cluster | `create_gke` | `existing_gke_cluster_name`, `existing_gke_prerequisites_attestation` | The n8n namespace, Secrets, Workload Identity binding, and Helm release still deploy onto the cluster |
| Controllers (KEDA, StorageClass) | `install_keda`, `create_pd_balanced_storage_class` | `existing_keda_prerequisites_attestation` (KEDA, only if `n8n_worker_keda_enabled = true`) | The n8n worker `ScaledObject`/`TriggerAuthentication` still target whatever KEDA install is effective |
| PostgreSQL | `create_postgres_instance` | `n8n_database_host` plus exactly one of `n8n_database_password` / `n8n_database_password_secret_ref` | n8n's `database.*` chart values and (unless a Secret reference is used) a Kubernetes Secret wrapping the password |
| Redis | `create_redis_instance` | `redis_host` (`redis_port`/`redis_tls_enabled`/`redis_username`/a password source as needed) | n8n's `redis.*` chart values, KEDA's `TriggerAuthentication` when any password source is present |
| GCS bucket | `create_gcs_bucket` | `existing_gcs_bucket_name` | Bucket-scoped IAM for the effective HMAC identity (module-managed or BYO) |
| GCS HMAC identity | (independent input) `gcs_hmac_service_account_email` | `gcs_hmac_access_id` plus `gcs_hmac_secret_name` or `gcs_hmac_secret` | The bucket IAM binding for that identity |
| Cloud KMS (Cloud SQL / Redis / GCS / GKE) | `create_postgres_kms_key` / `create_redis_kms_key` / `create_gcs_kms_key` / `create_gke_kms_key` | `existing_postgres_kms_key_id` / `existing_redis_kms_key_id` / `existing_gcs_kms_key_id` / `existing_gke_kms_key_id` | Nothing; the module grants no IAM on a supplied existing key, grant the relevant service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter` out of band |
| KMS key ring | `create_kms_key_ring` | `existing_kms_key_ring_id` (only if any `create_*_kms_key` is true) | Nothing |
| Namespace | `create_namespace` | `n8n_kube_namespace` names the existing namespace | Every namespaced resource (Secrets, ServiceAccount, Helm release) still targets it |
| Core Secret | (independent input) `existing_n8n_core_secret_name` | `n8n_license_key_secret_ref` (the chart's core-Secret contract forbids a plain `n8n_license_key` alongside it) | Nothing for the core Secret/encryption key; other Secrets (DB, Redis, GCS HMAC) are independent |
| License Secret | (independent input) `n8n_license_key_secret_ref` | n/a (mutually exclusive with `n8n_license_key`) | Nothing |
| Ingress | `create_ingress` | none required; use the stable service/route outputs (below) to build your own | The n8n Helm release still creates the `n8n_main_service_name`/`n8n_webhook_service_name` Services |
| Main/webhook HPA, worker KEDA | `n8n_main_hpa_enabled`, `n8n_webhook_hpa_enabled`, `n8n_worker_keda_enabled` | none required; `*_fixed_replicas` sets the replica count while disabled | Nothing; own a replacement `HorizontalPodAutoscaler`/`ScaledObject` under a different name to avoid a collision |

## Layer-by-layer detail

### Network and Private Service Access

`create_network = false` omits the VPC, subnetwork, secondary ranges, Cloud
Router, and Cloud NAT. Supply `existing_network_name`,
`existing_subnetwork_name`, `existing_pods_range_name`, and
`existing_services_range_name`; add `existing_network_project_id` for a
Shared VPC host project different from `project_id`. GKE and any
module-managed Cloud SQL/Memorystore instance attach to these effective
coordinates instead of a module-created network.

`create_psa = false` omits the Private Service Access range and service
networking connection independently of network ownership. Set
`existing_psa_prerequisites_attestation = true` when the target network
already has a compatible PSA connection and the module also creates Cloud SQL
or Memorystore. The module never reads or verifies the existing connection.

**Security boundary:** the module never mutates firewall rules, routes, or
peerings it does not create.

**Destroy on a customer-managed network with `create_psa = true`:** the module
abandons its service networking connection on destroy by default
(`psa_connection_abandon_on_destroy`), so the `servicenetworking-googleapis-com`
peering it created stays attached to your VPC while the module-owned PSA
address range is deleted. Removing that peering, and re-deploying the module
onto the same VPC afterwards, is covered in
[destroy-cleanup.md](./destroy-cleanup.md#private-service-access-connection-is-abandoned-not-deleted).

### GKE cluster

`create_gke = false` omits the cluster, node pool, node service account, and
node IAM bindings. Supply `existing_gke_cluster_name` (a regional cluster in
`gcp_region`) and set `existing_gke_prerequisites_attestation = true`. The
module still runs an observable-property check
(`data.google_container_cluster.existing`) at plan time: it enforces
VPC-native (alias IP) networking, Workload Identity enabled, and a
same-project Workload Identity pool unless `existing_gke_workload_identity_pool`
attests to an intentional cross-project binding. It trusts the attestation for
properties it cannot safely audit: reachability from your configured
providers, native ingress/metrics/autoscaling/PD CSI controllers, and
capacity for the requested n8n workload.

The `kubernetes`/`helm`/`kubectl` providers in your root must already be
configured against this cluster (copy the pattern in
[`examples/customer-managed-cluster/providers.tf`](../examples/customer-managed-cluster/providers.tf));
the module cannot bootstrap providers for a cluster it does not create.

**Security boundary:** the module creates no cluster-level RBAC beyond what
the n8n namespace needs; it never touches other namespaces or cluster-scoped
resources it does not own.

### Controllers (KEDA and the pd-balanced `StorageClass`)

The public [`modules/controllers`](../modules/controllers) submodule owns the
KEDA Helm release and the optional `pd-balanced` `StorageClass`. The root
module invokes it by default. Set `install_keda = false` to use an existing
KEDA installation; set `existing_keda_prerequisites_attestation = true`
whenever `n8n_worker_keda_enabled = true`, confirming a compatible KEDA
operator and CRDs are already running. `create_pd_balanced_storage_class`
is independent, and only affects stateful workloads that run beside n8n; n8n
itself is stateless.

You can also consume `modules/controllers` directly, outside this root
module, see
[`modules/controllers/examples/direct-use`](../modules/controllers/examples/direct-use)
for the explicit dependency a caller must add so KEDA installs before any
separately managed n8n `ScaledObject`.

### PostgreSQL

`create_postgres_instance = false` omits the Cloud SQL instance, generated
password, database, user, and the Cloud SQL-only
`google_project_iam_member.n8n_cloudsql_client` binding. Supply
`n8n_database_host` and exactly one of `n8n_database_password` (a direct
value) or `n8n_database_password_secret_ref` (a reference to an existing
Kubernetes Secret the module never reads). On the Secret-reference path the
module's own `kubernetes_secret.n8n_db` is skipped entirely.

Restore/clone inputs (`postgres_clone_source_instance_name`,
`postgres_clone_point_in_time`, `postgres_restore_backup_run_id`,
`postgres_restore_source_instance_name`) and Cloud KMS
(`create_postgres_kms_key`/`existing_postgres_kms_key_id`) only apply to a
newly created module-managed instance; they are ignored on the external path.
See [Restored/cloned database encryption-key continuity](#restoredcloned-database-encryption-key-continuity)
below.

### Redis

`create_redis_instance = false` omits the Memorystore instance. Supply
`redis_host`; `redis_port`, `redis_tls_enabled`, `redis_username`, and a
password source (`redis_password` or `redis_password_secret_ref`, mutually
exclusive) are optional depending on the target service. n8n and KEDA always
consume the same effective host/port/TLS/username/password-secret
coordinates regardless of ownership (`locals.tf`). KEDA's
`TriggerAuthentication` is created whenever any password source is present,
not only for managed AUTH.

`redis_key_prefix` and `n8n_redis_timeout_threshold_ms` apply on both paths
and stay synchronized across n8n's command channel (`N8N_REDIS_KEY_PREFIX`),
its Bull queue keys (the chart's `redis.prefix`), and KEDA's waiting/active
list names. Null omits both overrides, preserving n8n's own distinct `n8n`
command-channel and `bull` Bull-queue defaults rather than forcing them to
one value. See [Disruptive Redis transitions](#disruptive-redis-transitions)
below before changing `redis_key_prefix` on a live deployment.

### GCS bucket, HMAC identity, and encryption

`create_gcs_bucket = false` omits the bucket; supply
`existing_gcs_bucket_name`. Bucket ownership is independent from HMAC
identity ownership (`gcs_hmac_service_account_email`): the module always
grants least-privilege, bucket-scoped IAM to whichever HMAC identity is
effective, whether module-managed or BYO. See the root `README.md`
prerequisites section for the full BYO HMAC contract (locked-down orgs that
cannot relax `iam.disableServiceAccountKeyCreation` at all).

`create_gcs_kms_key`/`existing_gcs_kms_key_id` only take effect for a
module-managed bucket at creation; an existing bucket's encryption is never
mutated.

### Cloud KMS (shared key ring)

A single optional key ring (`create_kms_key_ring`/`existing_kms_key_ring_id`)
hosts every module-created CMEK key. Its creation is required only when at
least one service's `create_*_kms_key` switch is `true`. Each service
(`postgres`, `redis`, `gcs`, `gke`) has its own independent create-or-reference
pair; mixing, for example a module-created Cloud SQL key with an existing GCS
key, is supported. The module grants the appropriate Google Cloud service
agent `roles/cloudkms.cryptoKeyEncrypterDecrypter` only on a key it creates
itself; grant that role yourself on a supplied existing key.

`create_gke_kms_key`/`existing_gke_kms_key_id` configure the module-managed
GKE cluster's application-layer secrets encryption (etcd) via
`database_encryption`, granting the GKE service agent
(`service-<project_number>@container-engine-robot.iam.gserviceaccount.com`)
on a module-created key. Only takes effect for a module-managed cluster
(`create_gke = true`); ignored (with a warning) for an existing cluster.
Leaving both unset means the module does not manage this encryption: a new
cluster uses Google-managed encryption, but clearing the inputs on an
encrypted cluster does not decrypt it. Enabling encryption on an existing
cluster restarts the control plane while GKE re-encrypts every Secret. See
[Turning GKE secrets encryption off](./destroy-cleanup.md#turning-gke-secrets-encryption-off)
for the off procedure and for key-version guidance after rotation. The
effective key is exposed as the `gke_kms_key_id` output.

The ring location must satisfy every service sharing it. Cloud SQL,
Memorystore, and GKE require `gcp_region`. Cloud Storage requires the
bucket-compatible KMS location, with the `EU` bucket multi-region mapping to
the KMS `europe` multi-region. A GCS-only module-created ring selects that
location automatically. If regional Cloud SQL, Redis, or GKE shares the ring
with GCS, `gcs_location` must equal `gcp_region`; otherwise Terraform rejects
the plan because one key ring cannot occupy both locations.

### Namespace, Secrets, and Workload Identity

`create_namespace = false` deploys into an existing namespace
(`n8n_kube_namespace`) the module does not read, create, change, or delete.
Every namespaced resource routes through the same ordering-safe effective
namespace local regardless of ownership.

Typed existing-Secret references cover every credential family:

- `existing_n8n_core_secret_name`: the chart's core-Secret contract
  (`N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL`). When set,
  the module creates no core Secret and generates no encryption key, and
  `n8n_license_key_secret_ref` becomes required (the chart's core-Secret
  contract requires the license from a separate Secret, not
  `n8n_license_key`).
- `n8n_license_key_secret_ref`: the n8n Enterprise license, independent of
  the core-Secret decision.
- `n8n_database_password_secret_ref`, `redis_password_secret_ref`: as
  described above.
- `gcs_hmac_secret_name`: the GCS HMAC secret, in BYO HMAC mode.

The module never reads the contents of any referenced Secret; it only passes
the reference through to the n8n Helm chart.

Workload Identity binds the n8n Kubernetes ServiceAccount to a Google service
account regardless of GKE ownership, normalized to the effective (managed or
existing-cluster) Workload Identity pool and namespace, including a
cross-project pool via `existing_gke_workload_identity_pool`.

### Secret Manager and External Secrets

`n8n_external_secrets_enabled` (default `true`) is n8n's own generic External
Secrets feature switch; setting it `false` adds `external-secrets` to
`N8N_DISABLED_MODULES`. `n8n_secret_manager_enabled` is a separate opt-in that
grants the n8n Workload Identity Google service account
`roles/secretmanager.secretAccessor`, scoped to each secret listed in the
required, non-empty, wildcard-free `n8n_secret_manager_secret_ids` allow-list,
never project-wide. Configuring n8n's Google Secret Manager vault-provider
connection itself (Settings > External Secrets in the n8n UI) remains an
in-product operator action this module does not automate; it only grants the
IAM that connection needs at runtime.

`gke_secret_manager_addon_enabled` is an independent, cluster-level opt-in
(default `false`, gated on `create_gke = true`) that enables the
GKE-managed Secret Manager CSI driver add-on (`secret_manager_config`) on
the module-managed cluster. This lets a pod mount Secret Manager secrets as
files through a `SecretProviderClass` and a CSI volume (driver
`secrets-store-gke.csi.k8s.io`), both of which you own. Setting the input
back to `false` disables the add-on. Google requires GKE
1.27.14-gke.1042001 or later and Linux nodes for the add-on, and Workload
Identity Federation for GKE, which the module-managed cluster already has.

The add-on does not sync secrets into Kubernetes Secrets, so it does not
populate the Secrets that the `*_secret_ref` inputs read. Google provides that
as a separate
[secret synchronization](https://docs.cloud.google.com/secret-manager/docs/sync-k8-secrets)
feature, which this module does not configure.

The module grants no Secret Manager IAM for this add-on. Google's
[add-on documentation](https://docs.cloud.google.com/secret-manager/docs/secret-manager-managed-csi-component)
grants `roles/secretmanager.secretAccessor` on each secret directly to the
pod's Kubernetes ServiceAccount, through its Workload Identity principal.
`n8n_secret_manager_enabled` above grants n8n's Google service account
instead, for n8n's own External Secrets feature. It has not been verified as
a substitute for the add-on's grant.

### Application artifact and runtime portability

`n8n_image_repository`/`n8n_image_tag`, `n8n_task_runner_image_repository`/
`n8n_task_runner_image_tag`, and `n8n_chart_repository` let you point at a
private mirror or a custom image (for example one with community packages
baked in via `n8n_custom_extensions_path`). `n8n_image_pull_secrets` moves
ownership of the n8n Kubernetes ServiceAccount from the Helm chart to the
module (the pinned chart renders `imagePullSecrets` nowhere else), under a
different name than the chart's own default; the module carries over the
Workload Identity annotation onto the account it now owns.

`n8n_execution_data_storage_mode = "s3"` reuses the effective GCS bucket,
HMAC identity, and Secret contract this module already configures for binary
data, so no extra bucket or credentials are needed for object-storage
execution data.

### Ingress and application autoscaling

`create_ingress = false` omits the global address, Cloud DNS record, GKE
`Ingress`, `BackendConfig`, `FrontendConfig`, TLS resources, and
load-balancer teardown delay. The n8n Helm release still creates its
`Service` objects. Build a compatible ingress from the stable outputs:
`n8n_main_service_name`, `n8n_webhook_service_name`, `n8n_service_port`,
`n8n_main_route_prefixes`, and `n8n_webhook_route_prefixes` (the latter
covers `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`,
all of which must route to the webhook service, not the main service).

`n8n_main_hpa_enabled`, `n8n_webhook_hpa_enabled`, and
`n8n_worker_keda_enabled` are each independent. Disabling one omits the
corresponding `HorizontalPodAutoscaler`/`ScaledObject`/`TriggerAuthentication`
and falls back to the paired `*_fixed_replicas` input. Name any
customer-owned replacement scaler differently from the module's own resource
names to avoid a collision if you re-enable the module's scaler later.

## Effective, ownership-neutral outputs

Consume these outputs regardless of which layers you own; they resolve to
`null` only when the underlying attribute genuinely does not exist on the
selected path (for example, no Cloud SQL `connection_name` for an external
database):

| Output | Resolves to |
| --- | --- |
| `network_id`, `subnetwork_self_link` | Module-created or the supplied existing network/subnetwork |
| `gke_cluster_name`, `gke_cluster_endpoint`, `gke_cluster_ca_certificate` | Module-managed cluster, or the existing cluster named by `existing_gke_cluster_name` |
| `workload_identity_pool` | `<project_id>.svc.id.goog`, or `existing_gke_workload_identity_pool` |
| `postgres_host`, `postgres_kms_key_id` | Module-managed Cloud SQL, or the external database / KMS reference |
| `redis_host`, `redis_port`, `redis_tls_enabled`, `redis_username`, `redis_kms_key_id` | Module-managed Memorystore, or the external Redis / KMS reference |
| `gcs_bucket_name`, `gcs_kms_key_id` | Module-created bucket, or the existing bucket / KMS reference |
| `n8n_kube_namespace` | Module-created or the existing namespace |
| `n8n_main_service_name`, `n8n_webhook_service_name`, `n8n_service_port`, `n8n_main_route_prefixes`, `n8n_webhook_route_prefixes` | The n8n Helm release's Services and required route prefixes, for building a customer-managed ingress |

`postgres_private_ip` and `postgres_connection_name` stay Cloud-SQL-specific
(`null` when `create_postgres_instance = false`); use `postgres_host` for the
ownership-neutral host.

## Mixed-ownership patterns

Ownership switches are independent per layer, so any combination is valid:
an existing GKE cluster with a module-managed database, an existing database
with a module-managed cluster and ingress, or every layer customer-managed at
once ([`examples/customer-managed-everything`](../examples/customer-managed-everything)).
Cloud KMS ownership is even more granular: you can create a module-managed
key for Cloud SQL while referencing an existing key for GCS, all sharing (or
not sharing) the same key ring.

## Direct controller-submodule ordering

When composing `modules/controllers` outside this root module (rather than
letting the root's `install_keda` invoke it), add an explicit `depends_on`
from your own n8n Helm release (or any resource that creates a worker
`ScaledObject`) to the submodule, mirroring
[`modules/controllers/examples/direct-use`](../modules/controllers/examples/direct-use).
KEDA's CRDs must exist before a `ScaledObject` referencing them can apply.

## Disruptive Redis transitions

Changing `redis_key_prefix` on a deployment with in-flight or queued jobs
strands them under the old prefix, because both n8n's command channel
(`N8N_REDIS_KEY_PREFIX`) and Bull's key names (`redis.prefix`) embed the
prefix; every n8n role (main, worker, webhook processor) must pick up the
new value together, since a partial rollout would split main/worker
communication across two command-channel namespaces. Drain the queue (let
`n8n_worker_keda_min_replicas`/fixed workers run until the queue is empty)
before changing this value, then let the Helm upgrade restart all three
deployments rather than rolling them independently. The same applies when
switching `create_redis_instance` from `true` to `false` (or vice versa): the
new Redis endpoint starts with an empty queue, so any queued jobs on the old
endpoint are lost unless you drain first.

## Restored/cloned database encryption-key continuity

When the module manages the core Secret, it generates a new n8n encryption key
(`n8n_encryption_key`) for a fresh apply. If you restore or clone a Cloud SQL
instance from a backup that contains n8n credentials encrypted under a
different key, `postgres_restore_without_encryption_key_continuity` warns at
plan time. Those credentials are not decryptable until you manually reconcile
the encryption key out of band, for example by restoring the original
`n8n_encryption_key` value into the new deployment's core Secret before n8n
starts. Supplying `existing_n8n_core_secret_name` preserves the original key
and suppresses this warning.

## Existing-cluster provider bootstrapping

The `kubernetes`, `helm`, and `kubectl` providers need a real endpoint and CA
certificate to configure against. When `create_gke = true`, examples wire
these from the module's own outputs after the cluster exists. When
`create_gke = false`, those same outputs (`gke_cluster_endpoint`,
`gke_cluster_ca_certificate`) resolve from the existing cluster instead, but
your root must still supply Google Cloud credentials capable of reading that
cluster (via `google_client_config`, as in
[`examples/customer-managed-cluster/providers.tf`](../examples/customer-managed-cluster/providers.tf))
before the first `terraform plan` that references it.

## Workload Identity propagation

A Kubernetes ServiceAccount (KSA) newly annotated for Workload Identity does
not retroactively apply to already-running pods; only pods scheduled after
the annotation exists pick up the binding. If pods restarted before the
binding IAM member fully propagated fail Google API calls with permission
errors, restart the affected pods once more, see
[`docs/troubleshooting.md`](./troubleshooting.md#workload-identity-pods-cant-reach-cloud-sql-or-gcs).

## KEDA ordering and finalizers

KEDA must be installed, and its CRDs registered, before any `ScaledObject` or
`TriggerAuthentication` referencing them can apply; this module enforces that
ordering internally (root before `helm_release.n8n`, direct-use example
`depends_on`). On teardown, an already-uninstalled KEDA operator can leave
orphaned `ScaledObject` finalizers behind, blocking namespace deletion, see
[`docs/destroy-cleanup.md`](./destroy-cleanup.md#namespace-stuck-in-terminating).

## Cloud KMS permissions

A module-created CMEK key automatically grants the relevant Google Cloud
service agent (Cloud SQL, Memorystore, Cloud Storage, or GKE)
`roles/cloudkms.cryptoKeyEncrypterDecrypter` on that key. A supplied existing
key (`existing_postgres_kms_key_id`, `existing_redis_kms_key_id`,
`existing_gcs_kms_key_id`, `existing_gke_kms_key_id`) gets no IAM from the
module; grant the same role to the corresponding service agent out of band,
or the managed resource fails to create with a permission-denied error
referencing the key.

## Ingress route ownership

A customer-managed ingress must route every prefix in
`n8n_webhook_route_prefixes` (`/webhook`, `/webhook-waiting`, `/form`,
`/form-waiting`, `/mcp`) to `n8n_webhook_service_name`, and everything else to
`n8n_main_service_name`. Routing a webhook prefix to the main service instead
still serves traffic, but defeats the point of running dedicated webhook
processor pods (webhook load no longer isolates from UI/API load).

## Customer-managed resource teardown boundary

`terraform destroy` never deletes a resource this module did not create: an
existing network, GKE cluster, PostgreSQL database, Redis instance, GCS
bucket, namespace, KEDA installation, or Cloud KMS key is left untouched. Only
resources the module created (an empty `count = 0`/`for_each = {}` on every
customer-managed layer) are ever removed. Verify this with `terraform plan
-destroy` before a real destroy on a mixed-ownership deployment, confirming
the plan lists only module-owned resources.
