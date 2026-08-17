# capacity-guardrails Specification

## Purpose
Provides non-blocking capacity feedback when managed GKE node limits cannot
plausibly host the maximum application replica settings requested by callers.

## Requirements

### Requirement: Managed GKE capacity diagnostic
The module SHALL estimate maximum allocatable CPU and memory for a
module-managed regional GKE node pool and compare it with maximum n8n pod
requests using a documented system-reserve assumption.

#### Scenario: Requested replicas exceed estimated capacity
- **WHEN** the maximum requested main, worker, webhook, and task-runner capacity
  exceeds estimated managed node-pool capacity
- **THEN** the plan SHALL emit a warning identifying the constrained resource
  dimension
- **AND** SHALL NOT fail solely because of the estimate

#### Scenario: Requested replicas fit
- **WHEN** maximum pod requests fit within the estimated managed capacity
- **THEN** no capacity warning SHALL be emitted

### Requirement: Existing GKE capacity is not guessed
The module SHALL skip capacity estimation for customer-managed GKE clusters
whose node pools and autoscaling policies are outside module state.

#### Scenario: Existing GKE is selected
- **WHEN** `create_gke` is false
- **THEN** the module SHALL emit no computed capacity verdict
- **AND** SHALL document capacity as a caller prerequisite
