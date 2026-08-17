## Purpose

Defines independent ownership of namespaced Kubernetes resources, ingress, and
application scaling without resource collisions between the module and callers.

## ADDED Requirements

### Requirement: Existing namespace
The module SHALL support deploying n8n into an existing Kubernetes namespace
without reading, creating, changing, or deleting that namespace.

#### Scenario: Namespace ownership is disabled
- **WHEN** `create_namespace` is false
- **THEN** no namespace resource SHALL be planned
- **AND** all namespaced resources SHALL target `n8n_kube_namespace`

### Requirement: Existing Kubernetes credential Secrets
The module SHALL accept typed existing Secret references for the n8n license,
encryption key or core configuration, PostgreSQL password, Redis password, and
GCS HMAC secret, and SHALL NOT read the referenced values into Terraform state.

#### Scenario: Existing Secret replaces a direct value
- **WHEN** a valid Secret reference is supplied for a credential
- **THEN** the corresponding module-managed Secret or direct chart value SHALL
  be omitted
- **AND** n8n or KEDA SHALL reference the supplied Secret name and key

#### Scenario: Secret sources conflict
- **WHEN** both a direct credential value and its Secret reference are supplied
- **THEN** the plan SHALL fail with a mutual-exclusivity validation error

#### Scenario: Existing core Secret is selected
- **WHEN** an existing core Secret supplies n8n encryption and host settings
- **THEN** the module SHALL omit its core Secret
- **AND** SHALL require the license to come from a separate Secret reference

### Requirement: Customer-managed ingress
The module SHALL allow callers to own ingress, load-balancer address, DNS, TLS,
and GKE ingress custom resources while preserving stable service and routing
outputs.

#### Scenario: Managed ingress is disabled
- **WHEN** `create_ingress` is false
- **THEN** the module SHALL create no global load-balancer address, Cloud DNS
  record, ingress, BackendConfig, FrontendConfig, managed certificate,
  pre-shared certificate, or ingress teardown delay

#### Scenario: Caller builds ingress from outputs
- **WHEN** n8n is planned with customer-managed ingress
- **THEN** outputs SHALL identify the host, service names, service port, and
  required main and webhook route prefixes
- **AND** the webhook routes SHALL include `/webhook`, `/webhook-waiting`,
  `/form`, `/form-waiting`, and `/mcp`

### Requirement: Managed ingress security controls
The managed ingress SHALL support an explicit Google Cloud SSL policy and
either a module-created CIDR allow-list policy or an existing Cloud Armor
security policy.

#### Scenario: Source CIDRs are restricted
- **WHEN** ingress source CIDRs are supplied
- **THEN** only those CIDRs SHALL be allowed by the module-managed Cloud Armor
  policy
- **AND** unmatched sources SHALL be denied

#### Scenario: Cloud Armor sources conflict
- **WHEN** both source CIDRs and an existing Cloud Armor policy are supplied
- **THEN** the plan SHALL fail with a mutual-exclusivity error

### Requirement: Independent application scaler ownership
The module SHALL independently control the main HPA, webhook HPA, and worker
KEDA ScaledObject so callers can own any scaler without a resource collision.

#### Scenario: Caller owns one scaler
- **WHEN** one scaler's ownership switch is false
- **THEN** the module SHALL omit only that scaler
- **AND** other enabled scalers SHALL remain managed

#### Scenario: Worker KEDA is disabled
- **WHEN** worker KEDA is disabled
- **THEN** workers SHALL run at the configured fixed replica count
- **AND** no n8n worker ScaledObject SHALL be rendered by the module
