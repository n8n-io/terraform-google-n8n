# Tasks

Every section must leave the repo green: `terraform fmt -recursive`,
`terraform validate`, `terraform test`, `tflint`, and
`terraform-docs --output-check .` in the module root and in all five examples
(the godaddy example needs `GODADDY_API_KEY=stub GODADDY_API_SECRET=stub`).
Renames therefore land end-to-end per section: module, outputs, examples,
tests, generated docs, and a CHANGELOG bullet together.

## 1. Naming foundation

- [x] 1.1 Add `friendly_name_prefix` (required, validated per design D1) and
      `common_labels` (validated per design D2); remove `cluster_name`
- [x] 1.2 Replace `local.cluster_name` with a prefix-derived local and update
      every resource name (`gke.tf`, `cloudsql.tf`, `memorystore.tf`,
      `gcs.tf`, `network.tf`, `workload_identity.tf`, `dns.tf`, and any other
      file using `local.cluster_name`); merge `common_labels` into
      `local.gcp_labels`
- [x] 1.3 Rename outputs `cluster_name`, `cluster_endpoint`,
      `cluster_ca_certificate` to `gke_cluster_name`, `gke_cluster_endpoint`,
      `gke_cluster_ca_certificate`
- [x] 1.4 Update all five examples and their tests plus the root test suite;
      add assertions: prefix-derived cluster name, `common_labels`
      propagation, validator rejection via `expect_failures`
- [x] 1.5 Regenerate terraform-docs everywhere, add CHANGELOG bullets under
      `## [Unreleased] / ### Changed` (breaking), run the full local loop

## 2. Database interface rename

- [ ] 2.1 Rename the Cloud SQL and database variables per design D3
      (`postgres_*`, `n8n_database_*`, `create_postgres_instance`),
      preserving types, defaults, and cross-variable validations
- [ ] 2.2 Update all module references (`cloudsql.tf`, `n8n.tf`, `locals.tf`)
      and rename outputs `cloudsql_private_ip`, `cloudsql_connection_name`,
      `db_password` per design D4
- [ ] 2.3 Update examples, tests (including the external-database validation
      assertion under the new names), regenerate terraform-docs, add
      CHANGELOG bullets, run the full local loop

## 3. Redis and GKE interface rename

- [ ] 3.1 Rename `memorystore_*` variables to `redis_*` and the node and
      control-plane variables to `gke_*` per design D3
- [ ] 3.2 Update module references (`memorystore.tf`, `gke.tf`, `n8n.tf`) and
      rename output `memorystore_host` to `redis_host`
- [ ] 3.3 Update examples, tests, regenerate terraform-docs, add CHANGELOG
      bullets, run the full local loop

## 4. Application and DNS interface rename

- [ ] 4.1 Rename `n8n_domain` to `n8n_fqdn`, `namespace` to
      `n8n_kube_namespace`, `k8s_service_account_name` to
      `n8n_kube_svc_account`, `dns_managed_zone` to `cloud_dns_zone_name`
- [ ] 4.2 Update module references (`n8n.tf`, `dns.tf`, `crds.tf`,
      `workload_identity.tf`, `locals.tf`) and rename output `namespace` to
      `n8n_kube_namespace`
- [ ] 4.3 Update examples, tests, regenerate terraform-docs, add CHANGELOG
      bullets, run the full local loop

## 5. Operator docs

- [ ] 5.1 Write `docs/troubleshooting.md` mirroring the
      `terraform-aws-n8n/docs/troubleshooting.md` section structure, adapted
      per design D7, using only the renamed interface
- [ ] 5.2 Update `docs/post-deployment.md`, `docs/destroy-cleanup.md`, the
      README prose (usage snippets outside the generated block), example
      READMEs, and `AGENTS.md` for the renamed variables, outputs, and
      resource names
- [ ] 5.3 Verify no stale former names remain outside `CHANGELOG.md` and
      `openspec/` (`git grep` for each removed name); run markdownlint if
      configured and the full local loop

## 6. Housekeeping

- [ ] 6.1 Align `.github/pull_request_template.md` and
      `.github/ISSUE_TEMPLATE/{bug,feature}.yml` with the `terraform-aws-n8n`
      versions, adapting provider-specific wording to Google Cloud
- [ ] 6.2 Add `.github/CODEOWNERS` with a `*` rule owned by `@jrx` and
      `@buddy-n8n`
- [ ] 6.3 Add `SUPPORT.md` linking GitHub issues and the n8n community forum,
      consistent in tone with `SECURITY.md`; add CHANGELOG bullets under
      `### Added`

## 7. Final verification

- [ ] 7.1 Repo-wide sweep: `git grep` every former name from design D3/D4 to
      confirm only `CHANGELOG.md` and `openspec/` reference them; confirm
      CHANGELOG lists every breaking rename
- [ ] 7.2 Run the complete local loop from `AGENTS.md` (root plus all five
      examples: fmt, validate, test, tflint, terraform-docs) and fix anything
      red
