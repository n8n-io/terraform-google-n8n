# Update module to HVD interface conventions

## Why

The module targets the Terraform Registry Partner Premier Tier, but its input
and output surface predates a comparison with HashiCorp's own reference
implementation for this stack shape,
`terraform-google-terraform-enterprise-gke-hvd` (HashiCorp Validated Design).
The HVD module establishes conventions the registry audience expects from a
partner-grade Google Cloud module: a `friendly_name_prefix` naming driver, a
`common_labels` input, service-oriented variable prefixes (`postgres_*`,
`redis_*`, `gcs_*`, `gke_*`) instead of Google product names (`cloudsql_*`,
`memorystore_*`), and app-scoped names for application settings
(`<app>_fqdn`, `<app>_kube_namespace`).

The module is pre-release, so this is the last cheap moment to make breaking
interface changes. At the same time the repository's community-health files
should match the sibling module `terraform-aws-n8n` so both registry listings
present a consistent project.

## What changes

- Add `friendly_name_prefix` as the naming driver for all Google Cloud
  resources, replacing `cluster_name`. Add `common_labels`, merged into the
  label set applied to every taggable resource.
- Rename variables to HVD-style, service-oriented names: `cloudsql_*` becomes
  `postgres_*`, `memorystore_*` becomes `redis_*`, `node_*` and control-plane
  variables gain the `gke_` prefix, and app-facing names become `n8n_fqdn`,
  `n8n_kube_namespace`, `n8n_kube_svc_account`, `n8n_database_*`,
  `cloud_dns_zone_name`, `create_postgres_instance`. Full mapping in
  `design.md`.
- Rename outputs to match (`postgres_private_ip`, `redis_host`,
  `gke_cluster_name`, and so on).
- Update all five examples, all `.tftest.hcl` suites, `README.md`
  (terraform-docs regenerated), `docs/`, and `AGENTS.md` for the new names.
- Add `docs/troubleshooting.md` mirroring the structure of the
  `terraform-aws-n8n` troubleshooting guide, adapted to GKE and Google Cloud.
- Add `.github/CODEOWNERS` and `SUPPORT.md`; align the pull-request template
  and issue templates with `terraform-aws-n8n`.
- Record every rename as a breaking change in `CHANGELOG.md` under
  `## [Unreleased]`.

## Non-goals

- No change to the single-apply architecture. The module keeps deploying n8n
  in-module via the `helm`, `kubernetes`, and `kubectl` providers. The HVD
  infra-only pattern (rendered Helm overrides plus CLI post-steps) is
  explicitly out of scope.
- No bring-your-own VPC or bring-your-own GKE cluster. The VPC design decision
  is deferred; the module keeps creating its own VPC and network variables
  (`subnet_cidr`, `pods_cidr`, `services_cidr`, `psa_prefix_length`) keep
  their names.
- No state migration (`moved` blocks). The module is pre-release.
- No copyright/SPDX headers, `.copywrite.hcl`, or `Taskfile.yml`.
- No secondary-region / disaster-recovery support.

## Capabilities

### New capabilities

- `module-interface`: HVD-aligned input and output contract (naming driver,
  labels, service-prefixed variables, renamed outputs).
- `project-housekeeping`: community-health files aligned with
  `terraform-aws-n8n` plus `CODEOWNERS` and `SUPPORT.md`.
- `operator-docs`: troubleshooting guide and rename-consistent operator
  documentation.

## Impact

- Breaking: every consumer-facing variable and output listed in `design.md`
  changes name. Examples, tests, README, and docs are updated in lockstep.
- Affected code: `variables.tf`, `variables_gcp.tf`, `outputs.tf`,
  `locals.tf`, every resource file that names a resource or reads a renamed
  variable, `examples/*`, `tests/*`, `docs/*`, `README.md`, `AGENTS.md`,
  `CHANGELOG.md`, `.github/*`.
