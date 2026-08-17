# module-interface Specification

## Purpose
TBD - created by archiving change update-module-to-hvd-conventions. Update Purpose after archive.

## Requirements

### Requirement: Friendly name prefix drives resource naming
The module SHALL expose a required `friendly_name_prefix` input that drives
the name of every Google Cloud resource the module creates, replacing the
former `cluster_name` input.

#### Scenario: Resource names derive from the prefix
- **WHEN** the module is planned with `friendly_name_prefix = "prod"`
- **THEN** the GKE cluster SHALL be named `prod-n8n`
- **AND** the Cloud SQL instance SHALL be named `prod-n8n-pg`
- **AND** the Memorystore instance SHALL be named `prod-n8n-redis`

#### Scenario: Invalid prefix is rejected at plan time
- **WHEN** the module is planned with a `friendly_name_prefix` that contains
  `n8n`, uses characters outside the RFC 1035 label charset, or exceeds the
  documented length cap
- **THEN** the plan SHALL fail with a validation error that explains the
  constraint

#### Scenario: cluster_name no longer exists
- **WHEN** a caller sets `cluster_name`
- **THEN** the plan SHALL fail because the variable is not declared

### Requirement: Common labels on all taggable resources
The module SHALL expose a `common_labels` input (`map(string)`, default `{}`)
whose entries are merged into the labels applied to every Google Cloud
resource that supports labels, with module-built-in labels winning on key
collision.

#### Scenario: Caller labels propagate
- **WHEN** the module is planned with `common_labels = { team = "platform" }`
- **THEN** labeled resources (for example the GKE cluster and the GCS bucket)
  SHALL carry the `team = "platform"` label

#### Scenario: Invalid label charset is rejected
- **WHEN** `common_labels` contains a key or value that violates Google Cloud
  label constraints (uppercase, too long, bad leading character)
- **THEN** the plan SHALL fail with a validation error

### Requirement: HVD-aligned variable names
The module SHALL expose its database, Redis, GKE, DNS, and application
identity inputs under the names defined in the design mapping (D3):
`postgres_*` for Cloud SQL settings, `redis_*` for Memorystore settings,
`gke_*` for cluster and node-pool settings, `n8n_database_*` and
`create_postgres_instance` for database identity and the external-database
toggle, and `n8n_fqdn`, `n8n_kube_namespace`, `n8n_kube_svc_account`,
`cloud_dns_zone_name` for application-facing settings. The former names SHALL
NOT be declared. Semantics, types, defaults, and validation behavior of each
renamed variable SHALL be preserved.

#### Scenario: Renamed variables are accepted with preserved defaults
- **WHEN** the module is planned without setting `postgres_machine_type`,
  `redis_memory_size_gb`, or `gke_node_type`
- **THEN** the plan SHALL use the same default values the former
  `cloudsql_tier`, `memorystore_memory_gb`, and `node_machine_type` variables
  had

#### Scenario: Old names are gone
- **WHEN** a caller sets `cloudsql_tier`, `memorystore_tier`,
  `node_machine_type`, `n8n_domain`, or `db_name`
- **THEN** the plan SHALL fail because the variables are not declared

#### Scenario: External database contract is preserved under new names
- **WHEN** the module is planned with `create_postgres_instance = false` and
  no `n8n_database_host`
- **THEN** the plan SHALL fail with a validation error stating that
  `n8n_database_host` is required when `create_postgres_instance = false`

### Requirement: HVD-aligned output names
The module SHALL expose its outputs under the names defined in the design
mapping (D4), including `postgres_private_ip`, `postgres_connection_name`,
`n8n_database_password`, `redis_host`, `gke_cluster_name`,
`gke_cluster_endpoint`, `gke_cluster_ca_certificate`, and
`n8n_kube_namespace`. Sensitivity flags SHALL be unchanged. The former output
names SHALL NOT be declared.

#### Scenario: Renamed outputs resolve
- **WHEN** an example that references `module.n8n.gke_cluster_name` and
  `module.n8n.redis_host` is planned
- **THEN** the plan SHALL succeed and the outputs SHALL carry descriptions

### Requirement: Examples and tests use the new interface
All examples (`small`, `medium`, `large`, `cloudflare`, `godaddy`) and all
`terraform test` suites SHALL use only the new variable and output names, and
the generated README reference SHALL reflect the new interface.

#### Scenario: Example suites pass under mocks
- **WHEN** `terraform test` runs in the module root and in every example
- **THEN** all suites SHALL pass without Google Cloud credentials

#### Scenario: README reference is current
- **WHEN** `terraform-docs --output-check .` runs in the module root and in
  every example
- **THEN** the check SHALL report no drift

### Requirement: Ownership-neutral effective outputs
The module SHALL expose stable effective outputs for cluster, network,
PostgreSQL, Redis, GCS, namespace, Workload Identity, service routing, and
ingress coordinates regardless of whether each layer is module-managed or
customer-managed.

#### Scenario: Managed and customer-managed plans use the same output names
- **WHEN** equivalent managed and customer-managed configurations are planned
- **THEN** callers SHALL read the same output names for effective coordinates
- **AND** ownership-specific attributes that do not exist SHALL resolve to
  `null` rather than an invalid resource reference

### Requirement: Pre-release breaking interface
The module SHALL replace inconsistent pre-release inputs and resource addresses
where needed to provide the ownership model, without compatibility aliases or
`moved` blocks.

#### Scenario: Removed pre-release input is supplied
- **WHEN** a caller uses an input removed by the documented interface redesign
- **THEN** Terraform SHALL reject it as undeclared

#### Scenario: Breaking changes are discoverable
- **WHEN** a caller reads the changelog or customer-managed infrastructure guide
- **THEN** the removed and replacement inputs SHALL be listed
- **AND** the lack of automatic state migration SHALL be explicit

### Requirement: Opposite-path input diagnostics
The module SHALL fail incomplete selected ownership paths and warn when
non-sensitive inputs are supplied only to an unselected path.

#### Scenario: Managed-only setting is supplied for an existing resource
- **WHEN** a caller selects a customer-managed resource and sets a tuning input
  used only while creating that resource
- **THEN** the plan SHALL warn that the tuning input is ignored

### Requirement: Customer-managed examples
The repository SHALL provide runnable and mock-tested examples for an existing
GKE cluster, customer-managed Redis, customer-managed GCS, and a fully
customer-managed stack, plus a direct controller-submodule example.

#### Scenario: Example test matrix runs
- **WHEN** Terraform tests run in every example with mocked providers
- **THEN** every example SHALL plan without live Google Cloud credentials
- **AND** the fully customer-managed example SHALL plan no module-owned network,
  cluster, data-service, namespace, ingress, or scaler resources

### Requirement: Committed Terraform skill workflow
Implementation of this change SHALL follow the branch-local
`refactor-module`, `terraform-style-guide`, and `terraform-test` skills.

#### Scenario: Implementation begins
- **WHEN** an implementation agent starts a task section
- **THEN** it SHALL load the relevant committed Terraform skills
- **AND** use the repository's `AGENTS.md` rules where they are more specific
