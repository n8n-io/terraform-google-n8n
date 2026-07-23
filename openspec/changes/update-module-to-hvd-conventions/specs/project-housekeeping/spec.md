# Project housekeeping

## ADDED Requirements

### Requirement: Community-health files aligned with terraform-aws-n8n
The repository SHALL provide a pull-request template and issue templates
(`bug.yml`, `feature.yml`) whose structure matches the versions in
`terraform-aws-n8n`, with provider-specific wording adapted to Google Cloud
(GKE, Cloud SQL, Memorystore, GKE Ingress).

#### Scenario: Templates match the sibling structure
- **WHEN** `.github/pull_request_template.md` and
  `.github/ISSUE_TEMPLATE/*.yml` are compared with the `terraform-aws-n8n`
  versions
- **THEN** the sections and form fields SHALL match
- **AND** differences SHALL be limited to provider-specific wording

### Requirement: Code ownership file
The repository SHALL provide a `.github/CODEOWNERS` file assigning a default
owner for all paths.

#### Scenario: CODEOWNERS covers the repository
- **WHEN** `.github/CODEOWNERS` is read
- **THEN** it SHALL contain a `*` rule with at least one owner

### Requirement: Support policy
The repository SHALL provide a `SUPPORT.md` that tells users where to get
help (GitHub issues for bugs and feature requests, the n8n community forum
for usage questions) and is consistent in tone with `SECURITY.md`.

#### Scenario: Support entry points documented
- **WHEN** `SUPPORT.md` is read
- **THEN** it SHALL link to the repository issue tracker
- **AND** it SHALL link to the n8n community forum
