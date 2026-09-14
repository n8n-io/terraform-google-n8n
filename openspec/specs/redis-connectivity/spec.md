# redis-connectivity Specification

## Purpose
Defines one Redis connection and queue namespace contract shared by n8n and
KEDA across managed Memorystore and customer-managed Redis deployments.

## Requirements

### Requirement: Managed Redis topology and transport
Managed Redis SHALL support BASIC and STANDARD_HA topology, optional AUTH, and
in-transit encryption combinations supported by Google Cloud.

#### Scenario: High availability is selected
- **WHEN** STANDARD_HA is selected
- **THEN** the managed Redis instance SHALL use the high-availability tier
- **AND** n8n's Redis timeout budget SHALL be validated against the documented
  failover expectation

#### Scenario: Managed TLS and AUTH are enabled
- **WHEN** in-transit encryption and AUTH are enabled
- **THEN** both n8n and KEDA SHALL connect with TLS and the effective password
  Secret

### Requirement: External Redis connection
External Redis SHALL accept host, port, TLS, optional ACL username, and an
optional password supplied directly or through an existing Secret reference.

#### Scenario: External TLS and ACL credentials
- **WHEN** external Redis is selected with TLS, username, and password Secret
- **THEN** n8n and KEDA SHALL use the same host, port, TLS mode, username, and
  Secret reference

#### Scenario: Password sources conflict
- **WHEN** an external Redis password value and Secret reference are both set
- **THEN** the plan SHALL fail validation

### Requirement: Shared Redis key prefix
The module SHALL apply one optional Redis key prefix to n8n command keys, Bull queue keys, KEDA queue list names, and optional exporter key checks. It SHALL set both `N8N_REDIS_KEY_PREFIX` and `QUEUE_BULL_PREFIX` when a prefix is supplied. Null SHALL preserve n8n's distinct upstream command and Bull defaults rather than forcing them to one value.

#### Scenario: Prefix is set
- **WHEN** `redis_key_prefix` is set to a valid value
- **THEN** n8n SHALL namespace both its command channel and Bull queue keys with that value
- **AND** KEDA and the enabled exporter SHALL monitor the correspondingly prefixed waiting and active lists

#### Scenario: Prefix is malformed
- **WHEN** the prefix is blank or contains forbidden whitespace or separators
- **THEN** the plan SHALL fail validation

#### Scenario: Default prefixes remain distinct
- **WHEN** `redis_key_prefix` is null
- **THEN** the module SHALL emit no command-prefix or Bull-prefix override
- **AND** KEDA and the enabled exporter SHALL use `bull:jobs:wait` and `bull:jobs:active`

#### Scenario: Two deployments share Redis
- **WHEN** two rendered configurations use the same external Redis endpoint with different prefixes
- **THEN** their command-prefix values, Bull-prefix values, and observed queue keys SHALL be distinct

### Requirement: Redis transition safety
The module SHALL document queue-drain requirements for changes to Redis
topology, TLS, endpoint, credentials, or key prefix that can strand queued or
in-flight work.

#### Scenario: Operator plans a disruptive Redis change
- **WHEN** the customer-managed infrastructure guide is followed for a
  disruptive Redis transition
- **THEN** it SHALL require a maintenance window, a drained queue, and
  post-change KEDA and worker verification
