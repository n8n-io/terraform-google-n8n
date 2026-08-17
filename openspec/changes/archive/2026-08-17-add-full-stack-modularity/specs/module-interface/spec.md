## ADDED Requirements

### Requirement: Ownership-neutral effective outputs
The module SHALL expose stable effective outputs for cluster, network,
PostgreSQL, Redis, GCS, namespace, Workload Identity, service routing, and
ingress coordinates regardless of whether each layer is module-managed or
customer-managed.

#### Scenario: Managed and customer-managed plans use the same output names
- **WHEN** equivalent managed and customer-managed configurations are planned
- **THEN** callers SHALL read the same output names for effective coordinates
- **AND** ownership-specific attributes that do not exist SHALL resolve to
  `null` rather than an invalid resource reference

### Requirement: Pre-release breaking interface
The module SHALL replace inconsistent pre-release inputs and resource addresses
where needed to provide the ownership model, without compatibility aliases or
`moved` blocks.

#### Scenario: Removed pre-release input is supplied
- **WHEN** a caller uses an input removed by the documented interface redesign
- **THEN** Terraform SHALL reject it as undeclared

#### Scenario: Breaking changes are discoverable
- **WHEN** a caller reads the changelog or customer-managed infrastructure guide
- **THEN** the removed and replacement inputs SHALL be listed
- **AND** the lack of automatic state migration SHALL be explicit

### Requirement: Opposite-path input diagnostics
The module SHALL fail incomplete selected ownership paths and warn when
non-sensitive inputs are supplied only to an unselected path.

#### Scenario: Managed-only setting is supplied for an existing resource
- **WHEN** a caller selects a customer-managed resource and sets a tuning input
  used only while creating that resource
- **THEN** the plan SHALL warn that the tuning input is ignored

### Requirement: Customer-managed examples
The repository SHALL provide runnable and mock-tested examples for an existing
GKE cluster, customer-managed Redis, customer-managed GCS, and a fully
customer-managed stack, plus a direct controller-submodule example.

#### Scenario: Example test matrix runs
- **WHEN** Terraform tests run in every example with mocked providers
- **THEN** every example SHALL plan without live Google Cloud credentials
- **AND** the fully customer-managed example SHALL plan no module-owned network,
  cluster, data-service, namespace, ingress, or scaler resources

### Requirement: Committed Terraform skill workflow
Implementation of this change SHALL follow the branch-local
`refactor-module`, `terraform-style-guide`, and `terraform-test` skills.

#### Scenario: Implementation begins
- **WHEN** an implementation agent starts a task section
- **THEN** it SHALL load the relevant committed Terraform skills
- **AND** use the repository's `AGENTS.md` rules where they are more specific
