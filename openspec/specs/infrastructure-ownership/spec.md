# infrastructure-ownership Specification

## Purpose
Defines how callers select module-managed or customer-managed Google Cloud
infrastructure while n8n consumes one stable set of effective coordinates.

## Requirements

### Requirement: Explicit infrastructure ownership
The module SHALL expose non-null, plan-known ownership switches for the
network, GKE cluster, PostgreSQL instance, Redis instance, and GCS bucket, with
defaults that create each layer.

#### Scenario: Default deployment remains managed
- **WHEN** a caller uses the default ownership inputs
- **THEN** the plan SHALL create the network, GKE, Cloud SQL, Memorystore, and
  GCS resources required by n8n

#### Scenario: Customer-managed layer is omitted
- **WHEN** a caller disables creation for one infrastructure layer and supplies
  its required references
- **THEN** the plan SHALL create no resources owned exclusively by that layer
- **AND** n8n SHALL use the supplied coordinates

#### Scenario: Customer-managed references are incomplete
- **WHEN** a caller disables creation for a layer without supplying every
  required reference or prerequisite attestation
- **THEN** the plan SHALL fail with a validation error naming the missing
  contract

### Requirement: Customer-managed network and Private Service Access
The module SHALL support an existing VPC, subnetwork, pod and service secondary
ranges, and an independently managed Private Service Access connection.

#### Scenario: Existing network hosts managed data services
- **WHEN** `create_network` is false, Cloud SQL or Memorystore creation is
  enabled, and the required network and Private Service Access contract is set
- **THEN** the managed data service SHALL attach to the supplied network
- **AND** the module SHALL NOT create a VPC or subnetwork

#### Scenario: Existing Private Service Access is attested
- **WHEN** the caller owns the Private Service Access allocation and connection
- **THEN** the module SHALL require an explicit prerequisites attestation
- **AND** SHALL NOT attempt to mutate or delete the connection

### Requirement: Customer-managed GKE
The module SHALL support deployment to a readable existing regional GKE cluster
that meets documented VPC-native, Workload Identity, controller, reachability,
and capacity prerequisites.

#### Scenario: Existing GKE supplies effective coordinates
- **WHEN** `create_gke` is false and a valid existing cluster name and
  prerequisites attestation are supplied
- **THEN** the module SHALL use that cluster's name, endpoint, certificate
  authority, location, network, and Workload Identity pool
- **AND** SHALL NOT create a GKE cluster, node pool, node service account, or
  node IAM bindings

#### Scenario: Existing cluster is unreadable or incompatible
- **WHEN** the existing cluster lookup fails or an observable prerequisite does
  not match the supplied deployment contract
- **THEN** the plan SHALL fail before creating Kubernetes resources

### Requirement: Customer-managed data services
The module SHALL support external PostgreSQL and Redis and an existing GCS
bucket without reading customer-managed credentials from provider data sources.

#### Scenario: Fully customer-managed data plane
- **WHEN** PostgreSQL, Redis, and GCS creation are disabled and complete
  references are supplied
- **THEN** no Cloud SQL instance or child database/user, Memorystore instance,
  or GCS bucket SHALL be created
- **AND** n8n SHALL use the supplied host, port, bucket, and Secret references

#### Scenario: Bucket and HMAC ownership differ
- **WHEN** an existing GCS bucket is selected and module-managed HMAC creation
  is enabled
- **THEN** the module SHALL create only the HMAC identity resources and the
  scoped bucket access required by n8n

### Requirement: Customer-managed encryption keys
The module SHALL provide explicit create-or-reference Cloud KMS contracts for
managed Cloud SQL, Memorystore, and GCS resources where those services support
customer-managed encryption keys.

#### Scenario: Module-created service key
- **WHEN** a service's key-creation switch is enabled
- **THEN** the module SHALL create a key in the selected key ring
- **AND** grant only the service agent permissions required to use that key

#### Scenario: Existing key is selected
- **WHEN** key creation is disabled and a valid existing key ID is supplied
- **THEN** the managed service SHALL use the supplied key
- **AND** the module SHALL NOT create a replacement key

#### Scenario: Existing data service is selected
- **WHEN** a data service is customer-managed
- **THEN** its KMS creation and reference inputs SHALL have no effect on that
  service
- **AND** the plan SHALL emit an ignored-input diagnostic when such values are
  supplied

### Requirement: Managed PostgreSQL restore source
The module SHALL support provider-compatible backup or clone context when creating a new managed Cloud SQL instance and SHALL protect n8n encryption-key continuity through either a supplied direct key or an existing core Secret reference.

#### Scenario: Restore creates a managed instance
- **WHEN** a valid restore source is supplied with managed PostgreSQL enabled
- **THEN** the planned Cloud SQL instance SHALL use that source

#### Scenario: Restore lacks encryption-key continuity
- **WHEN** a restore source is supplied without a direct n8n encryption key or customer-managed core Secret reference
- **THEN** the plan SHALL warn that stored n8n credentials may be unreadable

#### Scenario: Caller supplies continuity
- **WHEN** a restore source is supplied with a valid direct key or existing core Secret reference
- **THEN** the missing-key-continuity warning SHALL NOT fire
- **AND** documentation SHALL still require the exact original key rather than imply Terraform verified it against the backup

### Requirement: Cloud SQL backup and query logging controls
Managed PostgreSQL SHALL accept optional retained-backup count and transaction-log retention using Cloud SQL semantics, not AWS retention days. Backup count SHALL be a whole number from one to 365. Transaction-log retention SHALL be whole days from one to seven for ENTERPRISE or one to 35 for ENTERPRISE_PLUS. Omitted values SHALL preserve existing provider-default behavior. Backups and point-in-time recovery SHALL remain enabled. Optional query logging SHALL default off and, when enabled, record DDL and statements taking at least 1000 ms rather than all statements.

#### Scenario: Explicit backup policy
- **WHEN** a managed Cloud SQL configuration supplies retained count 14 and transaction-log retention seven
- **THEN** the planned instance SHALL use COUNT retention of 14 backups and seven days of transaction logs
- **AND** backup/PITR enablement SHALL remain true

#### Scenario: Invalid edition-specific retention
- **WHEN** ENTERPRISE requests transaction-log retention of eight days
- **THEN** validation SHALL fail with the edition-specific limit

#### Scenario: Query logging is enabled
- **WHEN** managed query logging is enabled
- **THEN** the instance SHALL configure DDL and 1000 ms slow-statement logging
- **AND** documentation SHALL warn about query-text exposure

#### Scenario: External PostgreSQL owns these settings
- **WHEN** PostgreSQL is external and managed backup/logging tuning is supplied
- **THEN** the module SHALL create no managed database resources
- **AND** SHALL warn that those settings are ignored

### Requirement: Opt-in Memorystore RDB persistence
The module SHALL support opt-in RDB persistence for managed Memorystore with a validated period and optional RFC3339 start time. Defaults SHALL leave persistence disabled. Enabled persistence SHALL default to a 24-hour period and accept the documented one-, six-, twelve-, and 24-hour periods. External Redis SHALL remain untouched. Documentation SHALL distinguish automatic last-snapshot recovery from historical backups and warn about stale data, replay, and resource overhead.

#### Scenario: Managed persistence is enabled
- **WHEN** persistence is enabled with a six-hour period and a valid start timestamp
- **THEN** the planned Memorystore instance SHALL use RDB persistence with that schedule

#### Scenario: Persistence is unused
- **WHEN** persistence is disabled or Redis is customer-managed
- **THEN** no enabled managed RDB policy SHALL be applied
- **AND** explicitly supplied nondefault tuning for the unused path SHALL produce an ignored-input diagnostic

#### Scenario: Unsupported AWS-style retention is not offered
- **WHEN** the documented Redis persistence contract is reviewed
- **THEN** it SHALL NOT promise multiple historical restore points, zero data loss, or an ElastiCache-style snapshot-retention count
