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
The module SHALL apply one optional Redis key prefix to n8n command keys, Bull
queue keys, and KEDA queue list names.

#### Scenario: Prefix is set
- **WHEN** `redis_key_prefix` is set to a valid value
- **THEN** n8n SHALL namespace its Redis keys with that value
- **AND** KEDA SHALL monitor the correspondingly prefixed waiting and active
  lists

#### Scenario: Prefix is malformed
- **WHEN** the prefix is blank or contains forbidden whitespace or separators
- **THEN** the plan SHALL fail validation

### Requirement: Redis transition safety
The module SHALL document queue-drain requirements for changes to Redis
topology, TLS, endpoint, credentials, or key prefix that can strand queued or
in-flight work.

#### Scenario: Operator plans a disruptive Redis change
- **WHEN** the customer-managed infrastructure guide is followed for a
  disruptive Redis transition
- **THEN** it SHALL require a maintenance window, a drained queue, and
  post-change KEDA and worker verification
