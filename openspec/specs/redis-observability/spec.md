# redis-observability Specification

## Purpose
Expose optional queue metrics from the effective Redis connection without requiring a bundled monitoring stack or weakening Google-specific TLS verification.

## Requirements

### Requirement: Opt-in private Redis exporter
The module SHALL create one Recreate Redis exporter Deployment and a ClusterIP metrics Service on port 9121 only when `redis_exporter_enabled=true`. The image SHALL be explicitly versioned and configurable. This switch SHALL be independent of n8n metrics and KEDA ownership. The module SHALL expose a nullable exporter Service name and SHALL install no Prometheus or Grafana resources.

#### Scenario: Exporter is disabled
- **WHEN** exporter settings are left at their defaults
- **THEN** no exporter Deployment or Service SHALL be planned and its Service-name output SHALL be null

#### Scenario: Exporter without other metrics or KEDA
- **WHEN** the exporter is enabled while n8n metrics and worker KEDA are disabled
- **THEN** one Recreate exporter and a private metrics Service SHALL be planned
- **AND** no n8n metrics toggle or KEDA installation SHALL be implicitly enabled

### Requirement: Shared Redis connection and exact queue checks
The exporter SHALL use the effective Redis endpoint, TLS posture, ACL username, password Secret, and waiting/active queue keys used by n8n and KEDA. It SHALL read referenced credentials at runtime and SHALL NOT copy Secret payloads into Terraform data sources or inline endpoint URLs. Queue metrics SHALL use explicit key checks, not keyspace scans.

#### Scenario: External Redis with credentials
- **WHEN** external Redis specifies TLS, an ACL username, a password Secret reference, and a custom prefix
- **THEN** the exporter SHALL use those endpoint and Secret coordinates with the correct waiting/active keys
- **AND** no raw password SHALL appear in its planned environment values or address

### Requirement: Memorystore certificate verification
For module-managed Memorystore TLS, the exporter SHALL trust the module's Google service CA Secret while keeping certificate verification enabled. Non-TLS Redis SHALL not receive CA mounts. External Redis SHALL use its certificate-matching endpoint and existing documented trust contract; unsupported private CA or alias combinations SHALL NOT silently disable verification.

#### Scenario: Managed TLS configuration
- **WHEN** managed Memorystore transit encryption and the exporter are enabled
- **THEN** the exporter SHALL mount the service CA and configure its CA-file setting
- **AND** its configuration SHALL contain no TLS verification bypass

#### Scenario: Plaintext Redis
- **WHEN** Redis TLS is disabled
- **THEN** the exporter SHALL use the non-TLS endpoint and no TLS CA mount

### Requirement: Exporter hardening and ordering
The exporter SHALL run as non-root with dropped capabilities, no privilege escalation, read-only root filesystem, resource requests and limits, probes, and no Kubernetes API token mount. It SHALL wait for module-owned namespace/node prerequisites and remain available as a scrape target when Redis reports unavailable.

#### Scenario: Hardened pod contract
- **WHEN** the enabled exporter resource is inspected under mocks
- **THEN** tests SHALL verify each security, resource, and probe setting explicitly
- **AND** Service exposure SHALL remain ClusterIP with no public ingress route
