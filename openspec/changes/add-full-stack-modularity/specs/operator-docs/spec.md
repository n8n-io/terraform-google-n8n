## ADDED Requirements

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
