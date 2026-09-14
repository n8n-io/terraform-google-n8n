## MODIFIED Requirements

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
