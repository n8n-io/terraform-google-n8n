# operator-docs Specification

## Purpose
TBD - created by archiving change update-module-to-hvd-conventions. Update Purpose after archive.

## Requirements

### Requirement: Troubleshooting guide
The repository SHALL provide `docs/troubleshooting.md` that mirrors the
section structure of the `terraform-aws-n8n` troubleshooting guide, adapted
to this module's stack: GKE Ingress and ManagedCertificate instead of ALB and
ACM, Cloud SQL instead of RDS, Memorystore instead of ElastiCache, and
Workload Identity instead of IAM roles for service accounts.

#### Scenario: Guide covers the GKE stack
- **WHEN** `docs/troubleshooting.md` is read
- **THEN** it SHALL cover at minimum: ingress and certificate provisioning
  failures, DNS issues, pod scheduling and crash loops, database
  connectivity, Redis and worker-scaling issues, and where to find logs
  (`kubectl` and Cloud Logging)

#### Scenario: Commands match the module interface
- **WHEN** the guide references Terraform variables, outputs, or resource
  names
- **THEN** it SHALL use the renamed interface from this change

### Requirement: Existing docs consistent with the renamed interface
`README.md`, `docs/post-deployment.md`, `docs/destroy-cleanup.md`, the
example READMEs, and `AGENTS.md` SHALL reference only the renamed variables,
outputs, and resource names.

#### Scenario: No stale names remain
- **WHEN** the repository is searched for the former names (`cluster_name`
  as a module input, `cloudsql_tier`, `memorystore_*` variables,
  `n8n_domain`, `db_name`, `dns_managed_zone`, and the other names removed in
  the design mapping)
- **THEN** no matches SHALL remain outside `CHANGELOG.md` and the OpenSpec
  change folder

### Requirement: Customer-managed infrastructure guide
The repository SHALL document each ownership switch, required reference,
prerequisite attestation, security boundary, effective output, unsupported
combination, and mixed-ownership example.

#### Scenario: Operator selects a customer-managed layer
- **WHEN** an operator reads the customer-managed infrastructure guide
- **THEN** the guide SHALL identify exactly which resources the module omits
- **AND** which resources and permissions the module still creates

### Requirement: Transition and failure guidance
Operator documentation SHALL cover disruptive Redis transitions, restored
database encryption-key continuity, existing-cluster provider bootstrapping,
Workload Identity propagation, KEDA ordering and finalizers, referenced Secret
failures, ingress route ownership, Cloud KMS permissions, and customer-managed
resource teardown boundaries.

#### Scenario: Operator troubleshoots an existing-resource deployment
- **WHEN** a documented customer-managed failure occurs
- **THEN** `docs/troubleshooting.md` SHALL provide provider-appropriate
  diagnostic commands and a safe recovery sequence

### Requirement: Live verification guide
The smoke-test documentation SHALL define checks for each behavior that mocked providers cannot prove. Live checks SHALL be manual, require explicit operator approval and cloud access, and SHALL NOT gate implementation completion. Unperformed live checks SHALL be recorded as not run, not passed.

#### Scenario: Fully customer-managed stack is smoke-tested
- **WHEN** the documented smoke test runs after a real apply
- **THEN** it SHALL verify n8n health, Workload Identity, PostgreSQL, Redis TLS and AUTH where enabled, GCS object access, KEDA queue reads, Secret references, ingress routes, and absence of duplicate customer-owned resources

#### Scenario: New features receive a manual checklist
- **WHEN** implementation is delivered without live infrastructure access
- **THEN** the checklist SHALL include single-main rollout/drain and return to multi-main, Secret/ConfigMap refresh, restored-key credential decryption, separate-host OAuth, alias TLS, split-ingress exposure, Redis prefix isolation, exporter TLS/key metrics, and persistence recovery caveats
- **AND** destructive maintenance or recovery exercises SHALL require a disposable environment or a separate approved maintenance procedure
- **AND** these checks SHALL remain marked not run

### Requirement: Traceable cross-cloud scope
The repository SHALL document the AWS 0.4.0 source baseline and the disposition of cumulative feature groups. It SHALL distinguish ports, Google adaptations, existing behavior, and exclusions, with reasons for AWS-only or unsupported behavior. It SHALL NOT claim parity by merely renaming cloud resources.

#### Scenario: Operator reviews scope
- **WHEN** the applicability matrix is read
- **THEN** every reviewed feature group SHALL have a disposition and source or local evidence
- **AND** immediate-maintenance flags, cloud engine defaults, chart upgrade limitations, and AWS benchmark sizes SHALL have explicit exclusions or qualifications

### Requirement: Upgrade and runtime operations guide
The repository SHALL provide `docs/upgrading-n8n.md` and update existing guides for topology transitions, license Secret delivery, original-key recovery, new environment reservations, Secret/ConfigMap restart requirements, URL changes, Redis prefixes/persistence, and caller-owned ingress. It SHALL document the existing chart's reset-to-floor upgrade behavior instead of claiming scaler-owned replicas are fully preserved.

#### Scenario: Extra-env migration
- **WHEN** a previously accepted environment name becomes reserved
- **THEN** the upgrade guide SHALL identify its dedicated input and default
- **AND** any conditional reservation SHALL identify when the escape hatch remains valid

#### Scenario: Separate editor and webhook hosts
- **WHEN** an operator upgrades a split-host deployment
- **THEN** the guide SHALL identify the canonical editor OAuth callback host and require review of registered redirect URIs

#### Scenario: Reference-only configuration changes
- **WHEN** an operator rotates an overwrite Secret or changes a launcher ConfigMap
- **THEN** the guide SHALL identify which deployments need restarting
- **AND** SHALL NOT claim Terraform reads or hashes those contents

### Requirement: Google-specific sizing and operational evidence
Sizing guidance SHALL describe database pools as lazy per-process maxima and relate aggregate connection demand to replica ceilings and database capacity. It SHALL cover DNS, heap, ephemeral disk, pruning, and Redis snapshot considerations without importing AWS throughput guarantees or instance sizes. Example tables and prose SHALL match actual defaults.

#### Scenario: Large example sizing is reviewed
- **WHEN** the large example documentation and tests are compared with its variables
- **THEN** all replica and resource figures SHALL agree
- **AND** the example SHALL remain explicitly not scale-validated on GKE

#### Scenario: Managed service operation is planned
- **WHEN** the operator reads the database and Redis maintenance guidance
- **THEN** it SHALL distinguish Google service maintenance from Terraform configuration changes and describe plan/runtime inspection
- **AND** SHALL NOT instruct the operator to set an unsupported `apply_immediately` input
