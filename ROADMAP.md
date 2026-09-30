# Roadmap

This roadmap captures intent, not commitments. Items here are not on a
fixed timeline. See [`CHANGELOG.md`](./CHANGELOG.md) for what has
actually shipped.

## Phases

### Phase 1: Internal baseline

A minimal, lean Terraform module that is ready for publishing and
validated through n8n-internal testing.

### Phase 2: Lighthouse rollout

Publish the module and evaluate it through lighthouse customer
engagements, iterating early on real-world feedback.

### Phase 3: Multi-cloud parity

Keep this GCP module in step with the sibling AWS and Azure n8n modules,
reusing shared patterns for the Kubernetes workload layer.

## Candidate features

Features we may want to address along the way:

- Custom ENV variables via templates (SSO, Owner, etc.)

## Already shipped

Previously listed as candidates, now covered by the module or by n8n itself:

- **Install community packages via API.** `n8n_reinstall_missing_packages`,
  `n8n_community_packages_registry` and
  `n8n_community_packages_prevent_loading` (`variables.tf`) expose the
  relevant n8n settings, and the API surface itself is n8n's, documented in
  the n8n docs.
- **Bring your own Secret Manager secrets.** `n8n_secret_manager_enabled` and
  `n8n_secret_manager_secret_ids` (`variables.tf`) grant the n8n Workload
  Identity service account `roles/secretmanager.secretAccessor` on an
  explicit, wildcard-free allow-list of secrets, so n8n's External Secrets
  feature can read Google Secret Manager without a static key. The vault
  connection itself is still created in the n8n UI.
- **Bring your own certificates.** `tls_mode = "custom"` with
  `tls_cert_pem`/`tls_key_pem`, or `tls_mode = "secret"` with
  `tls_secret_name` (`variables_gcp.tf`), use a caller-supplied certificate
  instead of the Google-managed default; `examples/cloudflare` shows the
  cert-manager path.
- **Bring your own networking.** `create_network = false` with
  `existing_network_name`, `existing_subnetwork_name` and the existing
  secondary-range names (`variables_gcp.tf`) attaches to an existing VPC
  instead of creating one.
