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
- Install community packages via API
- Bring your own Secret Manager secrets
- Bring your own certificates
- Bring your own networking (deploy into an existing VPC)
