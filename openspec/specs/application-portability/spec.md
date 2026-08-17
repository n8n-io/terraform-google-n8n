# application-portability Specification

## Purpose
Defines portable application artifacts, storage, secret-manager access, and
runtime settings needed for restricted and production n8n deployments.

## Requirements

### Requirement: Custom application images
The module SHALL support independent n8n and task-runner image repositories and
tags, image pull policy, image pull Secrets, and a custom extensions path.

#### Scenario: Private images are selected
- **WHEN** private n8n and task-runner repositories and pull Secrets are
  supplied
- **THEN** every applicable pod SHALL use the selected image and pull Secret

#### Scenario: Chart image defaults are retained
- **WHEN** no custom image inputs are supplied
- **THEN** the chart's repository defaults SHALL remain unchanged
- **AND** the existing optional n8n image tag behavior SHALL remain available

### Requirement: Execution data storage mode
The module SHALL allow new execution data to use PostgreSQL or the effective
GCS S3-compatible object-storage contract and SHALL reject filesystem mode.

#### Scenario: Object storage is selected
- **WHEN** execution-data mode is `s3` and a complete effective GCS contract is
  available
- **THEN** n8n SHALL store new execution data through that object-storage
  contract

#### Scenario: Object storage contract is incomplete
- **WHEN** execution-data mode is `s3` without a usable bucket and HMAC Secret
- **THEN** the plan SHALL fail validation

### Requirement: Google Secret Manager access
The module SHALL optionally grant the n8n Workload Identity service account
read access to an explicit allow-list of Google Secret Manager secrets without
granting project-wide wildcard access.

#### Scenario: Allow-listed secrets are enabled
- **WHEN** Google Secret Manager integration is enabled with valid secret
  resource IDs
- **THEN** the n8n service account SHALL receive secret accessor permission on
  only those secrets

#### Scenario: Allow-list is unsafe or empty
- **WHEN** integration is enabled with an empty list, wildcard, or malformed
  secret resource ID
- **THEN** the plan SHALL fail validation

### Requirement: External Secrets runtime controls
The module SHALL expose n8n's External Secrets master switch and optional update
interval consistently across every n8n pod.

#### Scenario: External Secrets is disabled
- **WHEN** the master switch is false
- **THEN** `external-secrets` SHALL be included in n8n's disabled modules

#### Scenario: Update interval is configured
- **WHEN** an update interval is supplied while External Secrets is enabled
- **THEN** every n8n pod SHALL receive the corresponding n8n setting

### Requirement: Multi-main floating-license shutdown safety
The module SHALL default n8n to retain its floating license lease during normal
pod shutdowns.

#### Scenario: Default license behavior
- **WHEN** the caller does not override floating-license shutdown behavior
- **THEN** every n8n pod SHALL receive
  `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false`

### Requirement: Managed environment variable protection
The module SHALL prevent `n8n_extra_env` from overriding every connection,
identity, storage, license, topology, image, and External Secrets setting owned
by dedicated module inputs.

#### Scenario: Extra environment variable collides
- **WHEN** `n8n_extra_env` contains a newly reserved name or prefix
- **THEN** the plan SHALL fail validation and direct the caller to the dedicated
  input
