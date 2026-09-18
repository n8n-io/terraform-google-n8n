# release-verification Specification

## Purpose
Verify the Google parity change through reproducible automated checks while keeping cloud-dependent behavior explicitly separate from credential-free implementation acceptance.

## Requirements

### Requirement: Credential-free Terraform coverage
The root, every application example, controller submodule, and direct controller example SHALL pass formatting, validation, mocked plan tests, TFLint, and generated-documentation checks using the declared Terraform floor. New scenarios SHALL cover defaults, valid overrides, invalid inputs, managed/external paths, and independently disabled scalers. Tests SHALL NOT use live credentials or mock apply merely to resolve unknown Helm values.

#### Scenario: Minimum-version checks run
- **WHEN** the local or CI verification loop runs on Terraform 1.9.8
- **THEN** all declared targets SHALL validate and pass plan-time tests without cloud credentials
- **AND** nullable validations SHALL not fail due to unguarded function calls or list indexing

#### Scenario: Fully customer-managed composition remains valid
- **WHEN** the existing fully customer-managed test composition is planned with new features disabled
- **THEN** it SHALL still create no module-owned resources for the selected external layers

### Requirement: Shared-value chart rendering tests
CI SHALL render the actual pinned n8n chart using the relevant input-derived value fragments also consumed by the module. Assertions SHALL inspect the resulting Deployments, ConfigMaps, Services, PDBs, HPAs, and volume references where applicable. Tests SHALL use synthetic credentials, an isolated state location, and no cluster access.

#### Scenario: Runtime and topology matrix renders
- **WHEN** rendering tests run
- **THEN** they SHALL cover single-main and multi-main, fixed and managed scalers, database/queue/save controls, DNS/heap, caller mounts, credential overwrites, license references, launcher configuration, and URL/prefix wiring across affected roles
- **AND** SHALL detect a deliberately wrong tested value or duplicate newly managed environment entry

#### Scenario: Existing service behavior is proved
- **WHEN** managed ingress Service annotations are rendered
- **THEN** tests SHALL confirm the BackendConfig annotation reaches both main and webhook Services
- **AND** tests for caller-owned split-ingress Services SHALL verify their selectors against rendered pod labels

### Requirement: Curated blocking security checks
The repository SHALL pin and run the same security scan locally and in CI, fix genuine findings in scope, and document any retained intentional findings narrowly. After curation, unexpected findings SHALL fail CI. The change SHALL NOT use broad suppressions or preserve blanket `soft_fail=true` as its final security gate. Security-sensitive Kubernetes fields outside scanner coverage SHALL have explicit Terraform assertions.

#### Scenario: New violation is introduced
- **WHEN** a fixture or controlled verification introduces a previously unapproved security violation
- **THEN** the security command SHALL exit nonzero

#### Scenario: Exporter scanner coverage is incomplete
- **WHEN** the selected scanner does not inspect the version-suffixed exporter resource
- **THEN** explicit tests SHALL still enforce its non-root, capability, privilege, filesystem, token, probe, and resource settings

### Requirement: Example and local workflow coverage stays aligned
The split-ingress example SHALL include its own Terraform documentation configuration, README, example inputs, and mocked tests. CI and local instructions SHALL enumerate identical validation, testing, lint, and documentation targets. Local commands SHALL be runnable from the repository root without chained relative-directory errors.

#### Scenario: All-target verification
- **WHEN** a contributor follows the documented repository-root loop
- **THEN** it SHALL exercise every target covered by CI, including split ingress and both controller targets
- **AND** documentation checks SHALL render/check files rather than silently print CLI help
