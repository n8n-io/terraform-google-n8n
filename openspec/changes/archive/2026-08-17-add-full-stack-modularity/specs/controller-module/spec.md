## Purpose

Defines a reusable controller submodule and the root wrapper that install only
the optional cluster components owned by this Google Cloud module.

## ADDED Requirements

### Requirement: Public controller submodule
The repository SHALL provide `modules/controllers` as a directly consumable
Terraform submodule that owns KEDA and the optional balanced persistent-disk
StorageClass.

#### Scenario: Direct submodule defaults
- **WHEN** a caller invokes `modules/controllers` with its required cluster
  contract
- **THEN** KEDA and the StorageClass SHALL be created using pinned versions and
  non-null defaults

#### Scenario: Components are independently disabled
- **WHEN** KEDA installation or StorageClass creation is disabled
- **THEN** the corresponding resources SHALL be absent without disabling the
  other component

### Requirement: Root module wrapper
The root module SHALL invoke the controller submodule by default and expose its
installation and repository inputs without requiring direct submodule use.

#### Scenario: Root default preserves controller installation
- **WHEN** the root module uses default controller inputs
- **THEN** it SHALL install KEDA before creating n8n worker ScaledObjects

#### Scenario: Existing KEDA is used
- **WHEN** KEDA installation is disabled, worker KEDA remains enabled, and the
  existing-KEDA prerequisite is attested
- **THEN** the root module SHALL omit the KEDA Helm release
- **AND** SHALL still render worker KEDA resources

#### Scenario: Existing KEDA is not attested
- **WHEN** KEDA installation is disabled while worker KEDA remains enabled and
  no prerequisite attestation is supplied
- **THEN** the plan SHALL fail with an actionable validation error

### Requirement: Deterministic and mirrorable charts
The root and controller submodule SHALL accept HTTPS or OCI chart repositories
and exact semantic versions for every Helm release they own.

#### Scenario: Private mirror is selected
- **WHEN** a caller supplies private n8n and KEDA chart repositories
- **THEN** the corresponding Helm releases SHALL use those repositories

#### Scenario: Floating chart version is rejected
- **WHEN** a chart version is not an exact semantic version
- **THEN** the plan SHALL fail validation

### Requirement: Safe controller ordering
The module and documentation SHALL preserve installation and destruction order
between KEDA and n8n ScaledObjects.

#### Scenario: Root module is destroyed
- **WHEN** a root-managed deployment is destroyed
- **THEN** n8n ScaledObjects SHALL be removed while KEDA is still running
- **AND** KEDA SHALL be removed only afterward

#### Scenario: Controller submodule is used directly
- **WHEN** a caller composes the controller submodule with a separate n8n module
- **THEN** the documentation SHALL provide the explicit dependency needed to
  order n8n after KEDA
