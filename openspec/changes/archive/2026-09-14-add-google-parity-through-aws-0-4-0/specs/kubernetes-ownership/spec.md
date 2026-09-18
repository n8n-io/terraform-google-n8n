## ADDED Requirements

### Requirement: Direct encryption-key continuity
The module SHALL accept a sensitive `n8n_encryption_key` containing 64 hexadecimal characters, mutually exclusive with `existing_n8n_core_secret_name`. A supplied key SHALL replace generation on the managed-core path without changing the key's value. The sensitive output SHALL return the supplied/generated key, or null when the module references an unread external core Secret.

#### Scenario: Rebuild with the original key
- **WHEN** a valid original key is supplied without an external core Secret
- **THEN** the managed core Secret SHALL contain that exact key
- **AND** no random encryption key SHALL be generated

#### Scenario: Key sources conflict
- **WHEN** a direct key and an external core Secret are both supplied
- **THEN** validation SHALL reject the ambiguous sources

#### Scenario: Existing generation behavior
- **WHEN** neither key source is supplied
- **THEN** the module SHALL retain generated-key behavior and the sensitive recovery output

### Requirement: License values are delivered through Secrets
A direct license value SHALL be stored in a module-managed Kubernetes Secret and referenced by every n8n workload. The module SHALL NOT pass a literal license activation key in Helm values. Caller-managed license references SHALL remain unread and SHALL NOT create a duplicate managed license Secret. The existing external-core Secret contract SHALL continue to require a separate external license reference.

#### Scenario: Direct license key
- **WHEN** `n8n_license_key` supplies the license
- **THEN** main, worker, and webhook containers SHALL use the managed license Secret name/key
- **AND** rendered Helm values and pod specifications SHALL contain no literal license key

#### Scenario: Caller-managed license
- **WHEN** `n8n_license_key_secret_ref` is supplied
- **THEN** every n8n role SHALL reference that Secret
- **AND** the module SHALL neither read it nor create a managed license Secret

### Requirement: Credential-overwrite Secret reference
The module SHALL accept optional `n8n_credentials_overwrite_secret_ref={name,key}` and mount only that key read-only for every n8n role. It SHALL set `CREDENTIALS_OVERWRITE_DATA_FILE` to the mounted file without reading, hashing, or copying its contents. Missing Secret/key validation SHALL remain a runtime concern. Conflicting environment names, volume names, or overlapping mount paths SHALL fail validation while this input is enabled.

#### Scenario: Caller supplies an overwrite file
- **WHEN** a valid Secret reference is supplied
- **THEN** all three n8n roles SHALL mount the selected key at `/etc/n8n/credentials-overwrite/overwrites.json`
- **AND** each SHALL receive the file-path environment setting without the JSON payload

#### Scenario: Secret payload rotates
- **WHEN** the caller changes only the referenced Secret's contents
- **THEN** the module SHALL NOT claim or implement a payload-triggered rollout
- **AND** documentation SHALL require a restart of all n8n roles to load the new data

### Requirement: Canonical editor and webhook URLs
Every n8n role SHALL receive `N8N_EDITOR_BASE_URL` derived from `https://<n8n_fqdn>` and both current `N8N_WEBHOOK_URL` and legacy `WEBHOOK_URL` from the effective webhook base URL. The default webhook URL SHALL use the canonical hostname. Invalid HTTPS base URLs with credentials, query, or fragment SHALL fail validation.

#### Scenario: Split public hostnames
- **WHEN** `n8n_fqdn=editor.example.com` and `n8n_webhook_url=https://hooks.example.com`
- **THEN** the editor base SHALL be `https://editor.example.com`
- **AND** both webhook settings SHALL be `https://hooks.example.com`

#### Scenario: Default single hostname
- **WHEN** the webhook URL is omitted
- **THEN** all three public URL settings SHALL use `https://<n8n_fqdn>`

### Requirement: Additional managed ingress hosts
The module SHALL accept a non-null list of additional hostnames, normalize case, and reject malformed names, wildcards, duplicates, and repetition of the canonical hostname. Managed ingress SHALL give each hostname the full main/webhook route set and include it in module-owned DNS and certificate configuration. Aliases SHALL NOT change advertised canonical URLs. The effective host list SHALL be available as an output.

#### Scenario: Alias has complete routing and TLS
- **WHEN** an alias is supplied with managed ingress and Google-managed TLS
- **THEN** canonical and alias rules SHALL include the five webhook families and main catch-all
- **AND** the ManagedCertificate SHALL include both names
- **AND** configured module-owned Cloud DNS SHALL include both records

#### Scenario: Certificate modes cover aliases
- **WHEN** aliases are configured with self-signed or Secret-based TLS
- **THEN** generated certificate SANs or ingress TLS host declarations, respectively, SHALL contain every configured hostname
- **AND** custom/Secret certificate coverage SHALL remain a documented caller prerequisite

#### Scenario: Caller owns ingress
- **WHEN** aliases are supplied with `create_ingress=false`
- **THEN** they SHALL create no module-owned ingress, DNS, address, or certificate resources
- **AND** the effective host-list output SHALL still contain them

#### Scenario: Google certificate capacity is exceeded
- **WHEN** the total hostname count exceeds 100 in Google-managed certificate mode
- **THEN** Terraform validation SHALL reject it before provisioning

### Requirement: Guarded ingress annotations
The module SHALL accept optional non-conflicting ingress annotations without allowing caller annotations to override module-owned ingress class, static address, certificate, or FrontendConfig wiring. Nonempty annotations SHALL warn as ignored when the caller owns ingress.

#### Scenario: Annotation would redirect resource ownership
- **WHEN** a caller annotation sets the module-owned ingress class or static-address key
- **THEN** validation SHALL reject it and direct the caller to the dedicated ownership contract

### Requirement: Google split-ingress example
The repository SHALL provide a runnable and mock-tested example with public webhook-only ingress and private HTTPS editor ingress. It SHALL use Google's regional internal load-balancer prerequisites rather than AWS ALB settings. The example SHALL own the exposure-specific Services and backend configuration without taking over Helm-owned resources.

#### Scenario: Public endpoint cannot route to editor
- **WHEN** the split-ingress example is planned
- **THEN** its public ingress SHALL route only the five webhook families to webhook processors
- **AND** it SHALL contain no main-service backend or catch-all path

#### Scenario: Private editor routing is complete
- **WHEN** the split-ingress example is planned
- **THEN** its internal ingress SHALL use a regional internal address with proxy-only subnet/firewall prerequisites
- **AND** it SHALL route editor/API catch-all to main and webhook families to webhook processors with caller-supplied compatible TLS
- **AND** rendering tests SHALL confirm caller-owned Service selectors match the pinned chart's pod labels
