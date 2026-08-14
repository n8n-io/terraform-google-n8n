## 1. Ownership interface foundation

- [ ] 1.1 Load and follow the committed `refactor-module`,
  `terraform-style-guide`, and `terraform-test` skills, with `AGENTS.md` taking
  precedence where repository rules are more specific.
- [ ] 1.2 Define the complete non-null ownership switches, typed customer-managed
  references, prerequisite attestations, exact-version validators, and
  opposite-path diagnostics in `variables.tf` and `variables_gcp.tf`; remove or
  rename conflicting pre-release inputs rather than adding aliases.
- [ ] 1.3 Add ownership-neutral locals for network, cluster, namespace,
  PostgreSQL, Redis, GCS, secrets, Workload Identity, ingress, and service-route
  coordinates.
- [ ] 1.4 Rewrite outputs to use effective coordinates and return `null` for
  ownership-specific attributes that do not exist; add stable service and route
  outputs for customer-managed ingress.
- [ ] 1.5 Add mocked plan tests for defaults, nullability, selected-path missing
  references, supplied-but-ignored inputs, and removed pre-release inputs; run
  root format, validate, and targeted tests.

## 2. Network and Private Service Access ownership

- [ ] 2.1 Gate the VPC, subnetwork, secondary ranges, router, NAT, Private
  Service Access allocation and connection, and cleanup delay from static
  ownership inputs.
- [ ] 2.2 Wire existing network, Shared VPC project, subnetwork, secondary range,
  and independently owned Private Service Access references into effective
  locals and managed GKE or data services.
- [ ] 2.3 Add hard validation and prerequisite checks for every supported
  managed-network, existing-network, module-managed-PSA, and existing-PSA
  combination.
- [ ] 2.4 Add mocked plan tests proving omitted network resources and correct
  managed data-service network wiring; run root format, validate, and targeted
  tests.

## 3. GKE ownership

- [ ] 3.1 Gate the GKE cluster, node pool, node service account, and node IAM
  resources with `create_gke`, and add the existing regional GKE data lookup.
- [ ] 3.2 Normalize managed and existing cluster name, endpoint, certificate
  authority, location, network, and Workload Identity pool for providers,
  Kubernetes resources, Workload Identity, and outputs.
- [ ] 3.3 Add observable compatibility checks and the explicit existing-GKE
  prerequisites attestation without attempting to audit customer security
  posture.
- [ ] 3.4 Add mocked plan tests for managed GKE, existing GKE, missing
  prerequisites, mismatched observable properties, and absent cluster-only
  resources; run root format, validate, and targeted tests.

## 4. Public controller submodule

- [ ] 4.1 Create `modules/controllers` with standard module files and a typed,
  validated public contract for KEDA and the optional balanced-PD StorageClass.
- [ ] 4.2 Move KEDA Helm and StorageClass ownership into the submodule with
  independent non-null switches, private repository support, exact KEDA version,
  and safe install and destroy ordering.
- [ ] 4.3 Invoke the submodule from the root, implement the existing-KEDA
  prerequisites contract, and ensure root n8n ordering works when KEDA is
  installed internally or externally.
- [ ] 4.4 Add direct mocked submodule tests for defaults, each opt-out, private
  repository validation, and invalid versions; add a direct-use example that
  demonstrates explicit n8n dependency ordering.
- [ ] 4.5 Generate the submodule README reference and run format, init, validate,
  tests, TFLint, and terraform-docs for the submodule and root.

## 5. PostgreSQL ownership, restore, and encryption

- [ ] 5.1 Fully gate the Cloud SQL instance, random password, database, user, and
  Cloud SQL-only IAM resources so `create_postgres_instance=false` creates none
  of them.
- [ ] 5.2 Implement direct-password and existing Kubernetes Secret-reference
  paths for external PostgreSQL with mutual-exclusivity and completeness
  validation.
- [ ] 5.3 Add provider-supported Cloud SQL backup or clone restore inputs,
  source compatibility validation where observable, and the n8n
  encryption-key-continuity warning.
- [ ] 5.4 Add explicit key-ring and PostgreSQL Cloud KMS create-or-reference
  paths with key-scoped service-agent IAM and no mutation on external database
  paths.
- [ ] 5.5 Add mocked plan tests for managed, external, Secret-reference, restore,
  generated key, existing key, invalid, and ignored-input cases; run root format,
  validate, and targeted tests.

## 6. Redis ownership and connection contract

- [ ] 6.1 Gate Memorystore with `create_redis_instance` and add external host,
  port, TLS, ACL username, direct password, and password Secret-reference
  inputs with complete validation.
- [ ] 6.2 Implement managed BASIC and STANDARD_HA, AUTH, supported in-transit
  encryption, and explicit Redis Cloud KMS create-or-reference combinations.
- [ ] 6.3 Normalize Redis endpoint, TLS, username, and Secret wiring so n8n and
  KEDA always consume the same connection contract.
- [ ] 6.4 Add `redis_key_prefix` across n8n command keys, Bull queues, and KEDA
  waiting and active list names, plus the configurable Redis failover timeout
  threshold and disruptive-change diagnostics.
- [ ] 6.5 Add mocked plan tests for managed and external Redis, HA, TLS, AUTH,
  ACL, Secret references, KMS, prefix synchronization, invalid combinations,
  and ignored inputs; run root format, validate, and targeted tests.

## 7. GCS bucket, HMAC, and encryption ownership

- [ ] 7.1 Gate GCS bucket creation independently from the storage service
  account, bucket IAM, HMAC key, and Kubernetes HMAC Secret.
- [ ] 7.2 Implement existing-bucket combinations with module-managed or
  customer-managed HMAC identity and existing Secret references, using
  least-privilege bucket-scoped access.
- [ ] 7.3 Add explicit GCS Cloud KMS create-or-reference wiring and key-scoped
  service-agent IAM for managed buckets without mutating existing buckets.
- [ ] 7.4 Add mocked plan tests for every bucket/HMAC/Secret/KMS ownership
  combination and invalid or ignored inputs; run root format, validate, and
  targeted tests.

## 8. Namespace, Kubernetes Secrets, and Workload Identity

- [ ] 8.1 Gate namespace creation and replace resource-derived namespace
  references with an ordering-safe effective namespace contract.
- [ ] 8.2 Add typed existing Secret references for license, core encryption and
  host settings, PostgreSQL, Redis, and GCS, omitting each corresponding managed
  Secret or direct chart value without reading Secret contents.
- [ ] 8.3 Preserve generated task-runner token behavior and enforce the special
  core-Secret plus separate-license-Secret contract.
- [ ] 8.4 Normalize n8n Google service-account creation or reference and
  Workload Identity binding for managed and existing GKE, including
  cross-project pool validation where supported.
- [ ] 8.5 Add mocked plan tests for existing namespace, every Secret reference,
  conflicting sources, core-Secret requirements, Workload Identity paths, and
  absent managed resources; run root format, validate, and targeted tests.

## 9. Secret Manager and External Secrets

- [ ] 9.1 Add n8n External Secrets enablement and update-interval inputs and wire
  them consistently to every n8n pod.
- [ ] 9.2 Add Google Secret Manager integration with a required non-empty,
  wildcard-free allow-list of secret resource IDs and secret-scoped accessor IAM
  for the effective n8n Google service account.
- [ ] 9.3 Ensure Terraform-managed credentials are not accidentally exposed by
  broad IAM and document the remaining in-product vault-provider setup.
- [ ] 9.4 Add mocked plan tests for disabled External Secrets, update interval,
  valid allow-list IAM, empty/wildcard/malformed lists, and existing service
  account behavior; run root format, validate, and targeted tests.

## 10. Application artifact and runtime portability

- [ ] 10.1 Add custom n8n image repository, tag, pull policy, pull Secrets, and
  custom extensions path while retaining chart defaults when unset.
- [ ] 10.2 Add independent task-runner repository and tag inputs and apply the
  effective image and pull credentials to every applicable pod.
- [ ] 10.3 Add the n8n private chart-repository input and exact semantic version
  validation, consistent with the controller submodule repository contract.
- [ ] 10.4 Add `database` and GCS-backed `s3` execution-data storage modes,
  reject filesystem and incomplete object-storage contracts, and keep existing
  binary storage behavior intact.
- [ ] 10.5 Default floating-license shutdown detach to false and extend
  `n8n_extra_env` reserved-name checks for all new managed settings without
  regressing OpenTelemetry, log streaming, metrics, package, template, or
  personalization controls.
- [ ] 10.6 Add plan-time contract tests for image, chart, storage, license, and
  reserved environment behavior, with comments for Helm values that mocks leave
  unknown; run root format, validate, and targeted tests.

## 11. Ingress and autoscaling ownership

- [ ] 11.1 Gate the global address, Cloud DNS record, GKE ingress, BackendConfig,
  FrontendConfig, TLS resources, and load-balancer cleanup delay with
  `create_ingress`.
- [ ] 11.2 Correct and expose the complete route contract for webhook,
  webhook-waiting, form, form-waiting, MCP, and main traffic, and update managed
  ingress to route each path to the correct service.
- [ ] 11.3 Add managed-ingress SSL policy and mutually exclusive module-created
  CIDR allow-list or existing Cloud Armor security-policy support.
- [ ] 11.4 Add independent main HPA, webhook HPA, and worker KEDA switches and
  fixed replica settings so callers can own replacement scalers without name
  collisions.
- [ ] 11.5 Add mocked plan tests for managed and customer ingress, route outputs,
  TLS and Cloud Armor combinations, every scaler opt-out, and invalid inputs;
  run root format, validate, and targeted tests.

## 12. Capacity guardrails

- [ ] 12.1 Add the managed GKE machine-type lookup and documented regional node
  and system-reserve capacity calculation.
- [ ] 12.2 Add non-blocking CPU and memory checks covering maximum main, worker,
  webhook, and task-runner requests, and skip the verdict for existing GKE.
- [ ] 12.3 Add mocked tests for fitting capacity, CPU warning, memory warning,
  task-runner overhead, regional node maxima, and existing-GKE skip behavior;
  run root format, validate, and targeted tests.

## 13. Customer-managed examples and CI

- [ ] 13.1 Add runnable `customer-managed-cluster`, `customer-managed-redis`,
  `customer-managed-gcs`, and `customer-managed-everything` examples with
  providers, variables, outputs, generated references, and adaptation notes.
- [ ] 13.2 Add mocked example tests proving each ownership boundary and proving
  the all-customer-managed example creates no module-owned network, cluster,
  data service, namespace, ingress, or scaler.
- [ ] 13.3 Update existing small, medium, large, Cloudflare, and GoDaddy examples
  and tests for the breaking interface and new defaults.
- [ ] 13.4 Extend CI, repository guidance, and terraform-docs checks to the
  controller submodule and every new example; run the complete credential-free
  matrix with GoDaddy stub credentials.

## 14. Documentation and release contract

- [ ] 14.1 Write `docs/customer-managed-infrastructure.md` with the ownership
  matrix, required references, attestations, security boundary, effective
  outputs, mixed-ownership patterns, and direct controller-submodule ordering.
- [ ] 14.2 Expand troubleshooting for existing-GKE provider bootstrapping,
  Workload Identity propagation, referenced Secret errors, Redis transitions,
  KEDA finalizers, Cloud KMS IAM, ingress routes, and customer-owned teardown.
- [ ] 14.3 Update README prose, architecture, support matrix, security notes,
  out-of-scope section, all example READMEs, post-deployment docs, cleanup docs,
  AGENTS guidance, and generated Terraform references.
- [ ] 14.4 Record every new feature and every breaking input, output, and state
  change in `CHANGELOG.md`, explicitly stating that no automatic state migration
  is supported before the first release.
- [ ] 14.5 Extend smoke-test documentation and scripts for customer-managed
  layers, Redis TLS and AUTH, KEDA reads, Secret references, GCS access, ingress
  routes, and duplicate-resource detection.

## 15. Final verification

- [ ] 15.1 Run `terraform fmt -check -recursive`, init, validate, mocked tests,
  TFLint, and terraform-docs checks in the root, controller submodule, and every
  example; fix all failures.
- [ ] 15.2 Run Checkov and confirm the change introduces no unsuppressed curated
  regression; fix findings rather than adding inline suppressions.
- [ ] 15.3 In an approved disposable Google Cloud project, apply, smoke-test,
  and destroy the default stack and each independently customer-managed layer.
- [ ] 15.4 In an approved disposable Google Cloud project, apply, smoke-test,
  and destroy the fully customer-managed composition and direct controller
  submodule composition, verifying no customer-owned resource is changed or
  deleted.
- [ ] 15.5 Perform a final repository sweep for stale interface names,
  undocumented ownership combinations, generated-doc drift, temporary files,
  state files, plans, and credentials; validate the OpenSpec change with
  `openspec validate add-full-stack-modularity --strict`.
