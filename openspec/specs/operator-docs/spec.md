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
The smoke-test documentation SHALL define checks for each behavior that mocked
providers cannot prove.

#### Scenario: Fully customer-managed stack is smoke-tested
- **WHEN** the documented smoke test runs after a real apply
- **THEN** it SHALL verify n8n health, Workload Identity, PostgreSQL, Redis TLS
  and AUTH where enabled, GCS object access, KEDA queue reads, Secret references,
  ingress routes, and absence of duplicate customer-owned resources
