## Context

The root module creates a VPC and Private Service Access connection, GKE
cluster and node pool, Cloud SQL, Memorystore, a GCS bucket and HMAC identity,
Kubernetes namespace and Secrets, KEDA, a StorageClass, n8n, HPAs, GKE ingress
resources, DNS, TLS, and Workload Identity bindings. Only PostgreSQL and parts
of the GCS HMAC path currently accept customer-managed resources. The existing
`create_postgres_instance` path is incomplete because the Cloud SQL resources
are not cardinality-gated.

The reference architecture is `n8n-io/terraform-aws-n8n` PR #89. Its portable
pattern is an explicit, plan-known ownership boolean, required references on
the customer-managed path, diagnostics for ignored opposite-path inputs,
ownership-neutral internal values and outputs, and independent controller
ownership. Google Cloud differs because GKE supplies its ingress, metrics,
autoscaling, and persistent-disk controllers natively, while this module also
owns the VPC and Private Service Access connection.

This branch adds HashiCorp's `refactor-module`, `terraform-style-guide`, and
`terraform-test` skills. They are implementation inputs: refactoring must use a
cohesive public boundary, generated HCL must follow the repository's existing
layout where it is stricter than the generic style guide, and mocked plan tests
must cover every ownership combination that can be known at plan time.

## Goals / Non-Goals

**Goals:**

- Make every major infrastructure and Kubernetes layer independently
  customer-managed while preserving managed defaults.
- Let the root module remain a one-call greenfield deployment while exposing a
  directly consumable controller submodule.
- Keep credentials out of Terraform state whenever the caller supplies an
  existing Kubernetes Secret.
- Port useful cloud-neutral runtime behavior from the recent AWS work and add
  secure Google Cloud equivalents.
- Produce stable outputs and documented prerequisites for mixed-ownership and
  fully customer-managed deployments.

**Non-Goals:**

- Multi-region n8n, database replication, and disaster-recovery automation.
- Installing a general monitoring stack, OpenTelemetry collector, External
  Secrets Operator, cert-manager, or a non-GKE ingress controller.
- Proving the complete security posture of customer-managed resources. The
  module validates readable facts and requires explicit prerequisite
  attestations for properties Terraform cannot safely inspect.
- Preserving the current pre-release state addresses or old input names.
- Supporting filesystem execution or binary storage in the multi-main
  topology.

## Decisions

### D1: Use explicit static ownership switches

Each optional layer uses a non-null boolean whose default preserves the current
managed path. The initial contract is:

| Layer | Ownership input | Customer-managed reference |
| --- | --- | --- |
| Network and PSA | `create_network` | network, subnetwork, secondary ranges, and PSA attestation |
| GKE | `create_gke` | `existing_gke_cluster_name` and prerequisites attestation |
| Cloud SQL | `create_postgres_instance` | host plus password or Secret reference |
| Redis | `create_redis_instance` | host, port, TLS, username, and password or Secret reference |
| GCS bucket | `create_gcs_bucket` | `existing_gcs_bucket_name` plus HMAC identity inputs |
| Namespace | `create_namespace` | `n8n_kube_namespace` names the existing namespace |
| Ingress | `create_ingress` | caller owns ingress, address, DNS, and TLS |
| Main HPA | `n8n_main_hpa_enabled` | caller owns main scaling when false |
| Webhook HPA | `n8n_webhook_hpa_enabled` | caller owns webhook scaling when false |
| Worker KEDA | `n8n_worker_keda_enabled` | fixed replicas or caller-owned scaling when false |

Conditional resources use `count` because each switch controls zero or one
instance. The implementation must not infer cardinality from a resource-derived
name or ID because those values can be unknown during planning. Cross-variable
validation rejects incomplete customer-managed configurations. Terraform
`check` blocks warn when inputs are supplied on a path that ignores them.

Alternatives considered: inferring ownership from null references is terser but
fails when a reference comes from another resource; separate infrastructure and
application root modules would be cleaner but would remove the one-call default
and exceed the requested AWS parity.

### D2: Network ownership is a first-class prerequisite

`create_network=true` retains VPC, subnet, secondary ranges, NAT, Private
Service Access range, connection, and destroy-delay ownership. With
`create_network=false`, the caller supplies an existing network and subnetwork
plus pod and service secondary range names. The caller also chooses whether the
module manages a Private Service Access allocation and connection on that
network. If it does not, an explicit prerequisite attestation is required when
the module creates Cloud SQL or Memorystore.

An existing GKE data lookup supplies cluster coordinates, but does not silently
become the network contract. Explicit network references are still required
when the module creates network-attached data services. This avoids hidden
cross-project assumptions and supports a GKE cluster whose network lives in a
Shared VPC host project.

### D3: Normalize managed and existing GKE coordinates

`create_gke=false` reads the named regional cluster and requires an attestation
covering API reachability, Workload Identity, VPC-native networking, node
capacity, native GKE controllers, and permission to create namespaced
resources. Ownership-neutral locals expose name, endpoint, certificate
authority, location, network, and Workload Identity pool to provider consumers
and outputs. Cluster and node service accounts, node IAM, node pool, and
cluster-only dependencies are omitted on the existing path.

The module may still create the n8n Google service account and Workload Identity
binding on either path. The existing cluster's Workload Identity pool must match
the selected Google Cloud project, unless an explicit pool input supports a
cross-project binding.

### D4: Normalize data-service and encryption ownership

Cloud SQL, Redis, and GCS each expose effective coordinates through locals and
outputs. The module creates child database/user resources only with managed
Cloud SQL. Existing PostgreSQL accepts exactly one password source: a sensitive
value or a Kubernetes Secret reference. Existing Redis accepts TLS and optional
ACL username plus exactly one optional password source. Existing GCS accepts a
bucket name and keeps HMAC identity/key ownership independent from bucket
ownership.

Cloud KMS uses explicit creation booleans, not null inference. A shared key ring
can be module-managed or supplied, and PostgreSQL, Redis, and GCS each select a
module-created key, a supplied key ID, or provider-managed encryption where the
service permits it. Required Google-managed service-agent IAM bindings are
created only for keys the module is explicitly authorized to bind. Existing
resource paths do not mutate encryption settings.

Cloud SQL restore support is limited to provider-supported backup or clone
inputs for a newly managed instance. It validates source compatibility where a
data source exposes it and warns when no existing n8n encryption-key Secret is
provided. It does not automate cross-region recovery.

### D5: Keep one ownership-neutral application wiring contract

Downstream resources consume locals such as effective cluster coordinates,
network ID, PostgreSQL host and password Secret, Redis connection and Secret,
GCS bucket and HMAC Secret, and namespace. Outputs return these same effective
values, with `null` only for attributes that do not exist on a selected path.
This prevents ownership branches from spreading through `n8n.tf`, controller
wiring, and examples.

### D6: Extract only components this module installs

`modules/controllers` owns the KEDA Helm release and optional balanced
persistent-disk StorageClass. GKE's native ingress controller, metrics server,
cluster autoscaler, and PD CSI driver are prerequisites, not Helm releases.
The public submodule accepts cluster identity, namespace or ordering inputs,
common labels, `install_keda`, `create_pd_balanced_storage_class`, KEDA chart
repository and exact version, and any required provider aliases. Defaults are
non-null and repository URLs accept HTTPS or OCI forms.

The root module invokes the submodule by default. Direct users must order n8n
after the submodule when worker KEDA is enabled. `install_keda=false` with
`n8n_worker_keda_enabled=true` requires an explicit attestation that compatible
KEDA CRDs and an operator already exist. Destroy documentation preserves the
ordering that removes n8n ScaledObjects before uninstalling KEDA.

### D7: Separate secret identity from secret values

Typed references use `{ name = string, key = optional(string) }`. The module
does not read referenced Kubernetes Secrets. Direct values and references are
mutually exclusive, and required credentials accept exactly one source.
References cover license, encryption key or core Secret, database password,
Redis password, and GCS HMAC secret. The task-runner token remains generated
because it has no external continuity requirement.

When a whole existing core Secret supplies `N8N_ENCRYPTION_KEY`, `N8N_HOST`,
`N8N_PORT`, and `N8N_PROTOCOL`, the module omits its managed core Secret and
requires a separate license Secret reference. This follows the chart contract
without importing values into state.

Google Secret Manager integration is opt-in. It grants the n8n Workload
Identity Google service account `secretAccessor` only on an explicit,
wildcard-free list of Secret Manager secret resource IDs. Generic n8n External
Secrets can be disabled independently through `N8N_DISABLED_MODULES`; the
update interval is optional. Vault-provider connection setup in n8n remains an
operator action.

### D8: Treat Redis settings as one synchronized contract

Managed Memorystore supports BASIC or STANDARD_HA, optional AUTH, and optional
in-transit encryption where the selected service version and connection mode
support it. External Redis adds port, TLS, username, and password reference
inputs. KEDA receives the same endpoint, TLS, username, password reference, and
queue names as n8n.

`redis_key_prefix` sets n8n's command prefix, Bull queue prefix, and KEDA list
names together. A validator rejects blank values, whitespace, and separators
that would produce malformed keys. Changing the prefix is documented as a
queue migration that requires draining jobs first. A configurable n8n Redis
timeout threshold must exceed the expected managed failover window when
STANDARD_HA is selected.

### D9: Decouple ingress, routing, and autoscaling ownership

When `create_ingress=false`, the module omits the global address, Cloud DNS
record, GKE ingress, BackendConfig, FrontendConfig, managed or pre-shared
certificate resources, and load-balancer destroy delay. Outputs expose main and
webhook service names, port, host, and all required route prefixes, including
`/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`, so callers
can build a correct ingress.

Managed ingress can use an explicit Google Cloud SSL policy and an optional
Cloud Armor security policy. The policy can be module-created from source CIDRs
or referenced by name, but not both. Documentation warns that source
restrictions must include every webhook sender.

Main HPA, webhook HPA, and worker KEDA switches are independent. Disabling a
scaler leaves its workload at the configured fixed replica count and allows the
caller to create a replacement scaler without resource collision.

### D10: Complete application portability without duplicating existing work

The existing OpenTelemetry, log streaming, metrics, `n8n_extra_env`, package,
template, personalization, and image-tag controls remain. Image controls expand
to repository, tag, pull policy, pull Secret names, custom extension path, and
independent task-runner repository/tag. n8n and KEDA chart repositories become
inputs, and every chart version requires exact semantic version syntax.

`n8n_execution_data_storage_mode` accepts only `database` or `s3`. The S3 path
reuses the effective GCS S3-compatible storage contract and is rejected if that
contract is unavailable. Filesystem mode remains unsupported. The module emits
`N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false` by default to avoid multi-main
shutdown and restart loops, with a documented override only when an operator
intentionally wants detach behavior.

Reserved-name validation for `n8n_extra_env` expands for every newly managed
Redis, storage, license, image, and External Secrets environment variable.

### D11: Capacity checks are advisory and managed-cluster only

For module-managed GKE, a machine-type lookup and regional node maximum provide
estimated allocatable CPU and memory. Terraform `check` blocks compare that
capacity with maximum main, worker, webhook, and task-runner requests. They warn
when requested maxima cannot fit, accounting for regional zones and a
documented system-reserve margin. Existing GKE skips the estimate because node
pools can be heterogeneous and external autoscaling is outside module state.

### D12: Use a deliberate pre-release break instead of migration scaffolding

No `moved` blocks are required. The change may rename inputs, restructure
resources under `count`, and move controller addresses into the submodule.
`CHANGELOG.md` and the customer-managed guide must state that existing local
deployments need recreation or an operator-authored state migration. Before
the first release, all examples and documentation move to the new interface at
once.

### D13: Verification follows the committed Terraform skills

Implementation begins by loading and applying `refactor-module`,
`terraform-style-guide`, and `terraform-test`. Plan-time tests use mocked
providers for default, each independently customer-managed layer, mixed
ownership, fully customer-managed, invalid reference combinations, ignored
input warnings where testable, and the direct controller submodule. Provider
unknowns are handled at the variable contract level rather than by switching
to mocked apply tests. Live smoke-test instructions cover the security and
ordering behavior that mocks cannot prove.

Every task section must leave formatting and targeted tests green. Final
verification runs format, validate, tests, TFLint, and terraform-docs in the
root, controller submodule, and every example, plus Checkov and the live smoke
test in an approved disposable project.

## Risks / Trade-offs

- [One change has a large review surface] → Keep task sections ownership-based,
  make each section end-to-end and green, and avoid unrelated refactoring.
- [Existing-cluster provider configuration can become unknown and dial
  localhost] → Require readable cluster coordinates, document provider wiring,
  and add a dedicated existing-GKE example and troubleshooting section.
- [Skipping KEDA while ScaledObjects exist can deadlock deletion] → Validate
  prerequisites, retain explicit n8n-before-KEDA destroy ordering, and document
  the safe transition sequence.
- [Redis TLS or prefix transitions can abandon queued work] → Require a drained
  queue and maintenance window in migration guidance and smoke tests.
- [Secret references defer typo detection to Kubernetes] → Validate names and
  keys syntactically, document that existence is intentionally not read, and
  add pod-level smoke checks.
- [Customer-managed resources may be insecure or incompatible] → Validate only
  observable facts, require explicit attestations, and document the caller's
  security boundary.
- [Cloud KMS service-agent permissions vary by service and project] → Keep key
  ownership explicit, scope IAM per key, and test each managed service in a
  disposable Google Cloud project.
- [Capacity math is approximate] → Emit warnings rather than failures, publish
  assumptions, and skip heterogeneous existing clusters.
- [No state migration is supplied] → Mark the change as pre-release breaking in
  every entry point and require a clean deployment for supported validation.

## Migration Plan

1. Treat the implementation as the initial public interface, not an in-place
   upgrade. Update all examples and generated references together.
2. Validate a clean default deployment and destruction in a disposable project.
3. Validate customer-managed GKE, PostgreSQL, Redis, GCS, namespace, Secrets,
   KEDA, ingress, and all-customer-managed deployments individually and in
   combination.
4. Validate transitions that retain data only after draining Redis and backing
   up the n8n encryption key. Do not claim automated state compatibility.
5. Roll back by returning to the prior commit and recreating the disposable
   stack. Existing data-service rollback is an operator-owned restore process.
