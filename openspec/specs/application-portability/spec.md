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
The module SHALL prevent `n8n_extra_env` from overriding every connection, identity, storage, license, topology, image, External Secrets, and dedicated runtime setting owned by the module. It SHALL reserve the four execution-save names, current webhook URL, Redis command prefix, registry, task execution timeout, and compression/package controls. It SHALL reserve `NODE_OPTIONS` only while the heap input is set, and the two credential-overwrite names only while their dedicated Secret reference is set.

#### Scenario: Extra environment variable collides
- **WHEN** `n8n_extra_env` contains a newly reserved name or prefix
- **THEN** the plan SHALL fail validation and direct the caller to the dedicated input

#### Scenario: Optional ownership is inactive
- **WHEN** the heap and credential-overwrite inputs are null
- **THEN** existing escape-hatch use of `NODE_OPTIONS` and credential-overwrite names SHALL remain accepted

#### Scenario: Optional ownership is active
- **WHEN** the heap input is set alongside an extra `NODE_OPTIONS`, or the overwrite Secret reference is set alongside either overwrite environment name
- **THEN** Terraform validation SHALL reject the collision before rendering

### Requirement: Database health and acquisition controls
The module SHALL expose optional database ping timeout, ping interval, consecutive-failure count, and PostgreSQL connection-acquisition timeout on every n8n role for managed and external databases. Null values SHALL omit overrides. Acquisition timeout SHALL accept whole milliseconds from zero to 2147483647; zero SHALL disable that timeout. Other values SHALL be positive whole numbers in their documented units.

#### Scenario: External database tuning
- **WHEN** the caller uses external PostgreSQL and sets all four database tuning inputs
- **THEN** main, worker, and webhook containers SHALL receive the corresponding `DB_PING_TIMEOUT_MS`, `DB_PING_INTERVAL_SECONDS`, `DB_PING_MAX_FAILURES_BEFORE_RECOVERY`, and `DB_POSTGRESDB_CONNECTION_TIMEOUT` values

#### Scenario: Defaults and invalid timers
- **WHEN** the tuning inputs are null
- **THEN** no corresponding overrides SHALL be emitted
- **AND** a negative or overflowing acquisition timeout SHALL fail validation when supplied

### Requirement: Queue lease and stall controls
The module SHALL expose optional worker lock duration, renewal time, and stalled interval using the chart's existing queue settings without duplicate environment entries. Values SHALL be whole milliseconds at least 1000. Effective renewal SHALL be strictly less than effective duration, including omitted chart defaults. All configured siblings SHALL survive when supplied together.

#### Scenario: All queue settings are configured
- **WHEN** duration is 90000, renewal is 15000, and stalled interval is 45000
- **THEN** all three values SHALL appear in the rendered queue configuration used by n8n
- **AND** no extra environment entry SHALL compete with the chart's entry for those names

#### Scenario: Effective defaults make a lock invalid
- **WHEN** duration is 10000 and renewal is omitted
- **THEN** validation SHALL reject the configuration because the default renewal is not shorter than the duration
- **AND** stalled interval zero SHALL also be rejected while the pinned chart forbids it

### Requirement: Execution-save policy
The module SHALL independently expose success and error retention as `all` or `none`, progress saving as a boolean, and manual-execution saving as a boolean. Defaults SHALL remain all/all/false/true. Each setting SHALL reach every n8n role through one chart-owned environment entry.

#### Scenario: Mixed save policy
- **WHEN** success retention is none, error retention is all, progress saving is true, and manual saving is false
- **THEN** every n8n role SHALL receive exactly those four values
- **AND** each of the four `EXECUTIONS_DATA_SAVE_*` names SHALL appear once in that container's environment

### Requirement: Caller-managed volumes
The module SHALL accept typed references to existing ConfigMaps, Secrets, and PVCs and apply requested mounts to every n8n role. It SHALL create or read none of the referenced objects. Caller mounts SHALL coexist with module-owned Redis CA and credential-overwrite mounts without overriding protected names or paths.

#### Scenario: Custom files coexist with Redis TLS
- **WHEN** a caller mounts a ConfigMap at `/opt/n8n-nodes` and managed Memorystore TLS is enabled
- **THEN** all three n8n roles SHALL receive both the caller mount and the Redis CA mount
- **AND** a custom extensions path covered by that mount SHALL NOT warn solely because the image is stock

#### Scenario: Invalid or unsafe volume definition
- **WHEN** a volume has multiple sources, a mount references an undeclared volume, names or paths repeat, or a path overlaps a protected mount
- **THEN** Terraform validation SHALL reject it with the conflicting input identified

#### Scenario: Permission modes retain their meaning
- **WHEN** a Secret volume requests mode `"0440"`
- **THEN** the Kubernetes volume mode SHALL be decimal 288, not decimal 440

### Requirement: Task-runner launcher configuration and execution timeout
The module SHALL accept a caller-managed launcher ConfigMap name/key for enabled runners and a separate positive task execution timeout defaulting to 300 seconds. Launcher configuration SHALL mount on main and worker sidecars only, without reading its contents. Disabled runners with a custom launcher reference SHALL fail validation.

#### Scenario: Custom launcher is selected
- **WHEN** a valid custom launcher reference is supplied with task runners enabled
- **THEN** the selected ConfigMap key SHALL mount at the runner's launcher configuration path on main and worker pods
- **AND** no module-created ConfigMap or automatic payload-based rollout SHALL be introduced

#### Scenario: Execution and acceptance timeouts differ
- **WHEN** task execution timeout is 120 and the existing task acceptance timeout is 300
- **THEN** the rendered task broker settings SHALL retain those distinct values

### Requirement: Pod DNS and heap controls
The module SHALL expose optional validated pod DNS settings for all n8n roles and an optional global V8 old-space limit for n8n containers only. DNS settings SHALL validate nameserver addresses/count, search bounds, unique options, and `ndots` from zero to 15. The heap limit SHALL be a whole MiB value at least 256. Null SHALL preserve existing defaults.

#### Scenario: DNS and heap are set
- **WHEN** DNS options contain `ndots="1"` and the heap limit is 512
- **THEN** all three pod roles SHALL receive that DNS option
- **AND** all n8n containers SHALL receive `NODE_OPTIONS=--max-old-space-size=512`, without changing runner container heap settings

#### Scenario: Defaults and invalid DNS
- **WHEN** both settings are null
- **THEN** the module SHALL emit neither override
- **AND** configurations with a fourth nameserver, a hostname as a nameserver, or `ndots="16"` SHALL fail validation

### Requirement: Registry and security-related runtime controls
The module SHALL expose an optional custom community registry, optional unverified-package switch, and optional positive whole-number decompression size and archive-entry limits. Null SHALL omit each override so upstream security defaults can evolve. Custom registry configuration SHALL reject blank values, embedded credentials, and unsupported URL schemes.

#### Scenario: Security controls are explicit
- **WHEN** unverified packages are disabled and custom decompression and archive-entry limits are supplied
- **THEN** all n8n roles SHALL receive those settings
- **AND** leaving them null SHALL NOT pin upstream security defaults

#### Scenario: Custom registry is selected
- **WHEN** a valid HTTPS registry URL is supplied
- **THEN** every n8n role SHALL receive `N8N_COMMUNITY_PACKAGES_REGISTRY`
- **AND** documentation SHALL identify its separate entitlement and authentication responsibilities
