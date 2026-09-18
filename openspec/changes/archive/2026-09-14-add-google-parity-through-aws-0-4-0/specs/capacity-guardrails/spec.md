## MODIFIED Requirements

### Requirement: Managed GKE capacity diagnostic
The module SHALL estimate maximum allocatable CPU and memory for a module-managed regional GKE node pool and compare it with maximum n8n pod requests using a documented system-reserve assumption. It SHALL use the effective main ceiling after topology selection, include main/worker task-runner requests when enabled, and include the optional exporter's requests. Quantity inputs SHALL fail validation rather than causing parser errors when outside the documented supported grammar.

#### Scenario: Requested replicas exceed estimated capacity
- **WHEN** the maximum requested main, worker, webhook, task-runner, and enabled-exporter capacity exceeds estimated managed node-pool capacity
- **THEN** the plan SHALL emit a warning identifying the constrained resource dimension
- **AND** SHALL NOT fail solely because of the estimate

#### Scenario: Requested replicas fit
- **WHEN** maximum pod requests fit within the estimated managed capacity
- **THEN** no capacity warning SHALL be emitted

#### Scenario: Single-main effective ceiling
- **WHEN** single-main is selected with an unused configured main HPA maximum above one
- **THEN** the estimate SHALL count one main and its enabled runner, not the unused maximum

#### Scenario: Unsupported resource quantity
- **WHEN** a resource request cannot be parsed using the documented quantity grammar
- **THEN** variable validation SHALL identify the invalid input before capacity calculation fails
