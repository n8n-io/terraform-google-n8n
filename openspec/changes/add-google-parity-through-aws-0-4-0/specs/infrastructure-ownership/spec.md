## ADDED Requirements

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

## MODIFIED Requirements

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
