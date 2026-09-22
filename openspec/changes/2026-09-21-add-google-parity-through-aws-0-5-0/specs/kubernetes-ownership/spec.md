## MODIFIED Requirements

### Requirement: Hostname and Kubernetes-name inputs reject shapes downstream consumers always reject

`n8n_fqdn`, `n8n_additional_domains`, and `n8n_image_pull_secrets` SHALL validate every dot-separated label of each supplied name to the Kubernetes/DNS-1123 label rule: 1 to 63 characters, alphanumeric start and end, interior hyphens permitted. This is in addition to, not a replacement for, each input's existing whole-string checks (total length, malformed-shape rejection, wildcard rejection, duplicate rejection, canonical-hostname repetition on `n8n_additional_domains`, and the 100-domain `google_managed` certificate cap). The module SHALL reject an empty label, a label exceeding 63 characters, and a label starting or ending with a hyphen, regardless of its position in the name.

#### Scenario: Over-length label rejected

- **WHEN** `n8n_fqdn` or an entry of `n8n_additional_domains`/`n8n_image_pull_secrets` contains a dot-separated label longer than 63 characters
- **THEN** validation SHALL fail at plan

#### Scenario: Empty or hyphen-boundary interior label rejected

- **WHEN** a supplied name contains a label that is empty, or starts or ends with a hyphen, anywhere but the constraints already enforced on the first character of the whole string
- **THEN** validation SHALL fail at plan

#### Scenario: Valid multi-label names remain accepted

- **WHEN** every label of a supplied name is 1 to 63 characters and alphanumeric-bounded
- **THEN** validation SHALL succeed exactly as before this change

### Requirement: Self-signed certificate rejects an over-length Common Name

When `tls_mode = "self_signed"`, the module SHALL reject `n8n_fqdn` longer than 64 characters at plan, via a precondition on the self-signed certificate resource, rather than allowing the `tls` provider to fail mid-apply. This bound applies only to the self-signed path; `google_managed`, `custom`, and `secret` TLS modes retain only the existing 253-character whole-name limit, since they carry the hostname as a Subject Alternative Name, not a Common Name.

#### Scenario: Over-length hostname rejected under self-signed TLS

- **WHEN** `tls_mode = "self_signed"` and `n8n_fqdn` exceeds 64 characters
- **THEN** the plan SHALL fail with a precondition error naming the Common Name length limit

#### Scenario: Same hostname accepted under Google-managed TLS

- **WHEN** `tls_mode = "google_managed"` and `n8n_fqdn` is between 65 and 253 characters
- **THEN** the plan SHALL succeed, since the hostname is carried as a SAN, not a Common Name
