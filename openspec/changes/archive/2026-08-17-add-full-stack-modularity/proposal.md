## Why

The module currently assumes that it owns almost the entire Google Cloud and
Kubernetes stack. This prevents platform teams from adopting it when they
already operate shared networks, GKE clusters, Redis, object storage,
namespaces, secrets, ingress, or cluster controllers. The module is still
pre-release, so this is the lowest-cost point to establish the explicit
ownership model introduced by `terraform-aws-n8n` PR #89 and close the useful
cloud-neutral feature gaps identified in the AWS module's recent work.

## What Changes

- Add static `create_*` ownership switches and validated existing-resource
  references for the network, GKE, Cloud SQL PostgreSQL, Memorystore or
  external Redis, GCS, namespace, secrets, ingress, and autoscaling resources.
- Add ownership-neutral locals and outputs so n8n wiring and callers consume
  one contract whether infrastructure is module-managed or customer-managed.
- Extract KEDA and the optional GKE persistent-disk StorageClass into a public
  `modules/controllers` submodule. The root module continues to invoke it by
  default and exposes independent installation switches and chart mirrors.
- Add customer-managed Kubernetes Secret references for the n8n license,
  encryption key, database password, and Redis credentials without reading
  secret values into Terraform state.
- Add Google Secret Manager access for n8n through Workload Identity, scoped to
  an explicit secret allow-list, alongside n8n External Secrets controls.
- Add managed and customer-managed Cloud KMS options where Cloud SQL,
  Memorystore, and GCS support customer-managed encryption keys.
- Add Redis high availability, TLS, AUTH or ACL-compatible external
  credentials, failover timeout, and a shared key prefix synchronized across
  n8n, Bull queues, and KEDA.
- Add custom n8n and task-runner image repositories and tags, image pull
  secrets, private n8n and KEDA chart repositories, and exact chart-version
  validation.
- Add customer-owned main and webhook HPAs, customer-owned worker scaling,
  customer-owned ingress, stable service and route outputs, optional source
  restrictions through Cloud Armor, and explicit Google Cloud TLS policy
  selection.
- Add execution-data object-storage mode, floating-license shutdown behavior,
  Redis reconnect budgeting, and managed-cluster capacity diagnostics. Retain
  and integrate the module's existing OpenTelemetry, log streaming,
  `n8n_extra_env`, image pinning, package, template, and personalization
  controls rather than duplicating them.
- Add runnable customer-managed examples, direct controller-submodule tests,
  operator guidance, and a complete mocked plan-time test matrix.
- **BREAKING**: Redesign the pre-release input and output interface and allow
  resource addresses to change without `moved` blocks. Existing users must
  recreate or manually migrate state when adopting this unreleased interface.

## Capabilities

### New Capabilities

- `infrastructure-ownership`: Explicit module-managed and customer-managed
  contracts for Google Cloud network, GKE, PostgreSQL, Redis, GCS, and KMS.
- `kubernetes-ownership`: Explicit ownership of namespace, secrets, ingress,
  TLS and source controls, and application autoscaling resources.
- `controller-module`: Public controller submodule, root-wrapper behavior,
  installation switches, chart mirrors, and ordering contracts.
- `redis-connectivity`: Portable Redis HA, TLS, authentication, key namespace,
  KEDA synchronization, and failover behavior.
- `application-portability`: Portable images, registries, secret sources,
  execution storage, External Secrets, and production runtime controls.
- `capacity-guardrails`: Plan-time diagnostics for managed GKE capacity and
  requested n8n autoscaling maxima.

### Modified Capabilities

- `module-interface`: Extend the public interface with ownership-neutral
  references and outputs and permit a pre-release breaking redesign.
- `operator-docs`: Document customer-managed deployments, security boundaries,
  operational transitions, examples, and troubleshooting.

## Impact

- Affected root code includes all Terraform resource and interface files,
  especially `network.tf`, `gke.tf`, `cloudsql.tf`, `memorystore.tf`, `gcs.tf`,
  `workload_identity.tf`, `n8n.tf`, `crds.tf`, `keda.tf`, `scaling.tf`,
  `storage.tf`, `variables*.tf`, `locals.tf`, and `outputs.tf`.
- New public code under `modules/controllers` becomes a separately consumable
  Terraform Registry submodule with its own variables, outputs, tests, and
  generated documentation.
- Tests, examples, CI matrices, `README.md`, `CHANGELOG.md`, and operator docs
  expand to cover managed, mixed-ownership, and fully customer-managed paths.
- Terraform, provider, n8n chart, KEDA, Kubernetes CRD, Google Cloud IAM, and
  Secret Manager contracts require coordinated validation. Implementation
  SHALL use the branch-local `refactor-module`, `terraform-style-guide`, and
  `terraform-test` skills.
