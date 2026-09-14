## Purpose

Define single-main and multi-main queue-mode behavior so licensing, autoscaling, and maintenance settings agree across managed and caller-owned scaler paths.

## ADDED Requirements

### Requirement: Topology follows the selected main count
The module SHALL select single-main queue mode when the enabled main HPA minimum is one, or when the main HPA is disabled and the fixed main count is one. It SHALL select multi-main for larger selected counts and retain the current multi-main default. Workers, webhook processors, PostgreSQL, Redis, and shared binary storage SHALL remain configured in both modes.

#### Scenario: Managed single-main autoscaling
- **WHEN** the main HPA is enabled with minimum one and a configured maximum greater than one
- **THEN** multi-main leader election SHALL be disabled
- **AND** the main Deployment SHALL start with one replica and the HPA SHALL have minimum and maximum one

#### Scenario: Caller owns single-main scaling
- **WHEN** the main HPA is disabled and `n8n_main_fixed_replicas=1`
- **THEN** the module SHALL render one main replica without multi-main or a main HPA
- **AND** unused HPA settings SHALL NOT select multi-main

#### Scenario: Multi-main remains the default
- **WHEN** the caller does not change main topology inputs
- **THEN** the module SHALL retain multi-main and the configured main autoscaling bounds

### Requirement: Topology-aware maintenance
Single-main SHALL use a main-only Recreate rollout with no rolling-update parameters and a main disruption budget permitting eviction of its sole replica. Multi-main SHALL retain its existing rollout behavior and main disruption budget minimum of one. Worker and webhook rollout strategies SHALL NOT change with main topology.

#### Scenario: Single-main chart rendering
- **WHEN** single-main values are rendered against the pinned chart
- **THEN** the main strategy SHALL be Recreate with absent or null rolling-update settings
- **AND** its PDB SHALL select only main pods and set `minAvailable=0`
- **AND** worker and webhook strategies SHALL remain unchanged

#### Scenario: Topology returns to multi-main
- **WHEN** the selected main count changes from one to two
- **THEN** the rendered main rollout strategy and PDB SHALL return to multi-main settings
- **AND** the configured multi-main HPA maximum SHALL no longer be clamped to one

### Requirement: Valid scaling inputs
The module SHALL reject fractional, nonpositive, or reversed application replica bounds and invalid GKE per-zone bounds with input-specific errors. Fixed counts and scaler settings SHALL remain non-null. The webhook scale-up stabilization setting SHALL accept whole seconds from zero to 3600, default to zero, and have no effect when its HPA is caller-owned.

#### Scenario: Invalid bounds fail before chart rendering
- **WHEN** an application scaler minimum exceeds its maximum, a replica count is fractional, or a required bound is zero
- **THEN** Terraform validation SHALL reject the configuration

#### Scenario: Webhook stabilization is configured
- **WHEN** `n8n_webhook_hpa_scale_up_stabilization_window_seconds=60` and webhook HPA ownership is enabled
- **THEN** that HPA SHALL use a 60-second scale-up stabilization window
- **AND** disabling ownership SHALL omit that HPA entirely

### Requirement: Honest license and availability contract
Documentation SHALL identify Business single-main as avoiding the multi-main entitlement requirement, not all feature entitlements. It SHALL require an appropriate license, retain Enterprise multi-main guidance, and disclose editor, REST API, and scheduled-trigger downtime during single-main maintenance. It SHALL NOT promise at-most-one execution after node failure or manual pod deletion.

#### Scenario: Operator selects single-main
- **WHEN** the operator follows the documented single-main configuration
- **THEN** the instructions SHALL explain maintenance downtime, external-scaler restrictions, and separate entitlements for optional features
- **AND** SHALL NOT describe the mode as community-edition support
