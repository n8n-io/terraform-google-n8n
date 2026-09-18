# Baseline verification report

Captured before any implementation commit for `add-google-parity-through-aws-0-4-0`
(task 1.1). Records the exact commit, tag, chart digest, tool versions, and
CI/local check results this change starts from, so later sections have a fixed
point of comparison. Re-run the same commands after implementation (task 27)
and compare against this report.

## Commits and tags

- Google baseline commit: `f686a1d7f1020d69b42f5cee116af5f93f4e6342` (matches
  the commit already recorded in `parity-matrix.md`; no module code has
  changed since that review).
- AWS baseline tag: [`0.4.0`](https://github.com/n8n-io/terraform-aws-n8n/tree/0.4.0),
  commit `7e91a42f32df4cbcbcf8fc5229bb765c27202ff4` (no `v` prefix).
- n8n Helm chart: `ghcr.io/n8n-io/n8n-helm-chart/n8n:1.10.1`, digest
  `sha256:9bc2201221166c95d6c6d404d8ef568a371038a860e628ee85e21d96c68277dd`,
  re-pulled with `helm pull` during this report and confirmed to match the
  digest already recorded in `parity-matrix.md`.

## Tool versions used for this report

| Tool | Version | Source |
| --- | --- | --- |
| Terraform | `1.9.8` | Matches `TF_VERSION` pinned in `.github/workflows/terraform-tests.yml`; installed locally from the official release zip since the workstation's default `terraform` is a newer 1.16.x. |
| TFLint | `0.61.0` (workstation default) | CI pins `TFLINT_VERSION: v0.53.0` in `.github/workflows/terraform-tests.yml`; not reinstalled to the older pin for this report because no `.tf` changes are being validated yet. Section 24 revisits pinned-tool parity. |
| terraform-docs | `v0.24.0` | Matches the version pinned in `.github/workflows/terraform-tests.yml`'s `docs` job and the brew default named in `AGENTS.md`. |
| Helm | `v4.3.0+gbec5b06` (workstation default) | Not currently pinned anywhere in this repo; used only to re-pull the chart and confirm its digest. Section 1.3 adds a rendering script that should pin/record the Helm version it needs. |
| Checkov | `3.3.9` (workstation default via `checkov` on `PATH`) | CI's `checkov` job uses `bridgecrewio/checkov-action@v12` without an explicit Checkov version pin; the actual Checkov version that action resolves to may differ from `3.3.9`. Section 23.1 pins a specific Checkov version for both local and CI use. |

## Automated checks, run against Terraform 1.9.8

### `terraform fmt -check -recursive`, `terraform validate`, `terraform test` (module root)

```
terraform fmt -check -recursive   # no diff
terraform init -backend=false -input=false
terraform validate                # Success! The configuration is valid.
terraform test                    # Success! 229 passed, 0 failed.
```

### `terraform test`, every CI target

Ran `terraform init -backend=false` then `terraform test` in each target listed
in the `validate`/`test`/`tflint` job matrices of
`.github/workflows/terraform-tests.yml` (`GODADDY_API_KEY`/`GODADDY_API_SECRET`
stubbed for `examples/godaddy`, per `AGENTS.md`):

| Target | Result |
| --- | --- |
| `.` (module root) | 229 passed, 0 failed |
| `examples/small` | 1 passed, 0 failed |
| `examples/cloudflare` | 1 passed, 0 failed |
| `examples/godaddy` | 1 passed, 0 failed |
| `examples/medium` | 1 passed, 0 failed |
| `examples/large` | 1 passed, 0 failed |
| `examples/customer-managed-cluster` | 1 passed, 0 failed |
| `examples/customer-managed-redis` | 1 passed, 0 failed |
| `examples/customer-managed-gcs` | 1 passed, 0 failed |
| `examples/customer-managed-everything` | 1 passed, 0 failed |
| `modules/controllers` | 9 passed, 0 failed |
| `modules/controllers/examples/direct-use` | 1 passed, 0 failed |

All twelve `validate`/`test` matrix targets from
`.github/workflows/terraform-tests.yml` are green on Terraform 1.9.8. This
matches the same twelve targets the `tflint` job matrix and the `docs` job's
per-directory `terraform-docs --output-check` steps cover (`docs` additionally
checks `modules/controllers/examples/direct-use` and the root, both already
listed above).

### Current CI job inventory (`.github/workflows/terraform-tests.yml`)

- `fmt`: `terraform fmt -check -recursive -diff` at the repo root.
- `docs`: `terraform-docs --output-check .` (or the equivalent
  `--config ../../.terraform-docs.yml` / `--config ../../../../.terraform-docs.yml`
  invocation for `modules/controllers` and its nested example) across the root
  and every example/module target above.
- `validate`: `terraform init -backend=false` + `terraform validate` across
  the same twelve targets.
- `test`: `terraform init -backend=false` + `terraform test -verbose` across
  the same twelve targets (`GODADDY_API_KEY`/`GODADDY_API_SECRET` stubbed for
  the whole job).
- `tflint`: `terraform init -backend=false` + `tflint --init` +
  `tflint --format compact` across the same twelve targets.
- `checkov`: `bridgecrewio/checkov-action@v12` against the repo root,
  `framework: terraform`, **`soft_fail: true`** (never fails the job today;
  section 24.2 flips this once the baseline below is curated).

No chart-rendering job exists yet; task 1.3 adds one and task 24.1 wires it
into this workflow.

## Checkov baseline (informational only; `soft_fail: true` today)

`checkov -d . --framework terraform --compact --quiet` (Checkov `3.3.9`, no
credentials, module root only, the same directory the CI `checkov` job scans):

```
Passed checks: 69, Failed checks: 28, Skipped checks: 0
```

Failed checks by ID (some IDs recur across resources, e.g. the KMS rotation
check applies to all three module-managed keys):

| Check ID | Failures | Description |
| --- | --- | --- |
| `CKV_GCP_43` | 3 | KMS key rotation period |
| `CKV2_GCP_18` | 2 | Default network firewall |
| `CKV2_GCP_13` | 2 | PostgreSQL `log_duration` flag |
| `CKV_GCP_97` | 1 | Memorystore in-transit encryption |
| `CKV_GCP_95` | 1 | Memorystore AUTH |
| `CKV_GCP_79` | 1 | Cloud SQL major-version currency |
| `CKV_GCP_69` | 1 | GKE metadata server |
| `CKV_GCP_68` | 1 | Shielded GKE node secure boot |
| `CKV_GCP_66` | 1 | GKE Binary Authorization |
| `CKV_GCP_65` | 1 | GKE RBAC via Google Groups |
| `CKV_GCP_62` | 1 | GCS bucket access logging |
| `CKV_GCP_61` | 1 | VPC flow logs / intranode visibility |
| `CKV_GCP_6` | 1 | Cloud SQL require-SSL |
| `CKV_GCP_54` | 1 | PostgreSQL `log_lock_waits` flag |
| `CKV_GCP_53` | 1 | PostgreSQL `log_disconnections` flag |
| `CKV_GCP_52` | 1 | PostgreSQL `log_connections` flag |
| `CKV_GCP_51` | 1 | PostgreSQL `log_checkpoints` flag |
| `CKV_GCP_26` | 1 | Subnet VPC flow logs |
| `CKV_GCP_13` | 1 | GKE client certificate auth |
| `CKV_GCP_12` | 1 | GKE Network Policy |
| `CKV_GCP_111` | 1 | PostgreSQL statement logging |
| `CKV_GCP_110` | 1 | PostgreSQL `pgaudit` |
| `CKV_GCP_109` | 1 | PostgreSQL log level |
| `CKV_GCP_108` | 1 | PostgreSQL hostname logging |

This is the untouched baseline the module already carries with `soft_fail:
true`; it predates this change and is not itself in scope until section 23
curates it (fix genuine findings, add narrowly scoped documented exceptions
for real ownership-model conflicts, then flip `soft_fail` to `false` in
section 24.2). None of these findings are fixed or suppressed by this report.

## Section 23: curated Checkov security baseline

Captured after sections 1-22's implementation, using Checkov `3.3.17` (pinned
for local and CI use in section 23.1; see `CHANGELOG.md`'s section-23 entry
and `.github/workflows/terraform-tests.yml`'s `checkov` job, which now
references `bridgecrewio/checkov-action@v12.3123.0`, the release tag whose
bundled image is `ghcr.io/bridgecrewio/checkov:3.3.17`):

```
checkov -d . --framework terraform --compact --quiet
# Passed checks: 110, Failed checks: 0, Skipped checks: 162
```

The 28 distinct findings from this report's earlier Checkov `3.3.9` baseline
(module root only) are all accounted for below, scanning the whole repository
(root plus all 10 example/module call sites, hence the higher pass/skip
counts from the same set of underlying findings). Every skip below is a
resource-scoped Checkov `checkov:skip` comment placed inside the resource
body (a comment above the resource declaration does not suppress anything;
verified against a minimal fixture during this review), each pointing back to
a longer rationale comment on the same resource.

### Fixed (real configuration changes)

| Check | Resource | Fix |
| --- | --- | --- |
| `CKV_GCP_43` | `google_kms_crypto_key.postgres` / `.redis` / `.gcs` | `rotation_period = "7776000s"` (90 days) added to all three keys. |
| `CKV_GCP_26` | `google_compute_subnetwork.n8n` | Added a `log_config` block (5s aggregation, 0.5 sampling, full metadata). |
| `CKV2_GCP_18` (partially; see exceptions) | `google_compute_network.n8n` | Added an explicit, low-priority (65534) deny-all-ingress `google_compute_firewall.deny_all_ingress`, which changes no actual allowed traffic. |
| `CKV_GCP_51`/`52`/`53`/`54`/`108`/`109`, `CKV2_GCP_13` | `google_sql_database_instance.n8n` | Added always-on `log_connections`, `log_disconnections`, `log_checkpoints`, `log_lock_waits`, `log_duration`, `log_hostname`, `log_min_error_statement` database flags (none carry query text or parameter values); see also the scanner-limitation exception below for why Checkov still cannot see these. |
| `CKV_GCP_69` | `google_container_cluster.n8n` | Added a `node_config` block with `workload_metadata_config { mode = "GKE_METADATA" }` to the (immediately removed) default node pool template, matching the actual managed node pool's own setting. |
| `CKV_GCP_13` | `google_container_cluster.n8n` | Added `master_auth.client_certificate_config.issue_client_certificate = false`. |
| `CKV_GCP_61` | `google_container_cluster.n8n` | Added `enable_intranode_visibility = true`. |
| `CKV_GCP_12` | `google_container_cluster.n8n` | Added `datapath_provider = "ADVANCED_DATAPATH"` with `network_policy { enabled = false }` (Google's own recommended combination: Dataplane V2 enforces NetworkPolicy natively; enabling the legacy add-on alongside it is redundant and unsupported). |
| `CKV_GCP_68`, `CKV_GCP_72` | `google_container_node_pool.n8n` (and the cluster's template `node_config` above) | Added `shielded_instance_config { enable_secure_boot = true, enable_integrity_monitoring = true }` to both. |
| `CKV_GCP_62`, `CKV_GCP_78` | `google_storage_bucket.n8n` / new `google_storage_bucket.n8n_access_logs` | Added a dedicated, versioned, 30-day-lifecycle access-log bucket and pointed the binary-data bucket's `logging.log_bucket` at it. |

### Scanner limitations (config is correct; Checkov's static analysis cannot see it)

| Check | Resource | Why Checkov cannot see the fix |
| --- | --- | --- |
| `CKV_GCP_51`, `CKV_GCP_52`, `CKV_GCP_53`, `CKV_GCP_54`, `CKV_GCP_108`, `CKV_GCP_109`, `CKV2_GCP_13` | `google_sql_database_instance.n8n` | The flags above are emitted via a `dynamic "database_flags"` block. Reproduced against a minimal two-resource fixture during this review: an identical `name`/`value` pair passed every one of these checks as a literal `database_flags { ... }` block and failed all of them as a `dynamic "database_flags"` block with a literal `for_each` map. Verified instead by `tests/postgres_ownership.tftest.hcl`'s always-on-flags assertions (`query_logging_disabled_by_default_emits_no_flags` and neighbors). |
| `CKV_GCP_79` | `google_sql_database_instance.n8n` | The check hardcodes a single literal "latest" version per engine (currently `POSTGRES_18` only) that goes stale on every new Cloud SQL major-version release. `postgres_version` defaults to `POSTGRES_16` (Google's own extended support runs through 2032) and remains caller-configurable to any supported version, including the literal this check currently expects. |
| `CKV2_GCP_18` | `google_compute_network.n8n` | `google_compute_firewall.deny_all_ingress` (added above) is connected to this network and satisfies the check's actual intent (a non-default firewall exists). Reproduced against a two-resource fixture during this review: an identical network/firewall pair passed without `count`, and failed once both resources used `count = 1`, i.e. Checkov's graph connection lookup does not resolve a count-indexed `network = google_compute_network.n8n[0].id` reference. This module always sets `count` on this resource (`create_network`), so the false positive is unavoidable without dropping that ownership switch. |

### Intentional exceptions (fixing would contradict a documented design choice)

| Check | Resource | Why this is intentional |
| --- | --- | --- |
| `CKV_GCP_6` | `google_sql_database_instance.n8n` | `ssl_mode = ALLOW_UNENCRYPTED_AND_ENCRYPTED` (not `ENCRYPTED_ONLY`) matches n8n's own default `DB_POSTGRESDB_SSL_ENABLED=false` client behavior over a private VPC (Private Services Access, never a public IP). `db_postgresdb_ssl_enabled` lets an operator require SSL on the n8n client side without breaking connectivity for the documented default. |
| `CKV_GCP_110` | `google_sql_database_instance.n8n` | pgAudit is a heavier, always-on audit-logging feature beyond this change's opt-in DDL/slow-query logging (`postgres_query_logging_enabled`); not requested and not implied by AWS parity. An operator can add `cloudsql.enable_pgaudit = on` to the same `for_each` map this resource already builds `database_flags` from. |
| `CKV_GCP_111` | `google_sql_database_instance.n8n` | Forcing `log_statement=all/mod/ddl` for every instance would override `postgres_query_logging_enabled`'s own documented, opt-in scope (`log_statement=ddl` only, and only when explicitly enabled) with an always-on, potentially PII-carrying statement log. |
| `CKV_GCP_97`, `CKV_GCP_95` | `google_redis_instance.n8n` | `transit_encryption_mode`/`auth_enabled` default to `DISABLED`/`false`, matching n8n's own default unencrypted, unauthenticated Redis client behavior over a private VPC connection. `redis_transit_encryption_enabled`/`redis_auth_enabled` let an operator turn both on without any code change (and `locals.tf`'s `manage_redis_trigger_auth` already accounts for the resulting KEDA `TriggerAuthentication` requirement). |
| `CKV_GCP_65` | `google_container_cluster.n8n` | `authenticator_groups_config` requires an existing Google Group (e.g. `gke-security-groups@<domain>`) in the caller's own Cloud Identity/Workspace directory; this module cannot create or assume one on a generic project. |
| `CKV_GCP_66` | `google_container_cluster.n8n` | Binary Authorization requires a project-level admission policy and, to provide real protection, a separate attestor pipeline outside this module's GKE ownership scope (D3). Enabling it against an unconfigured project's default permissive policy adds an API dependency and a cluster field with no actual admission protection. |
| `CKV_GCP_62` | `google_storage_bucket.n8n_access_logs` | A log bucket does not log access to itself; nothing else in this module writes to it, and pointing it at another bucket would just move this same finding one bucket over. |

No resource lost an existing curated protection (e.g. the Cloud Armor
`cve-canary` rule from `add-full-stack-modularity`'s final verification is
unchanged), and no check was suppressed more broadly than the single resource
it was reproduced against.

## What this report does not verify

No live Google Cloud apply, no live Helm upgrade, no chart rendering (chart
1.10.1's `helm template` output is not yet exercised anywhere in this repo;
task 1.3 adds that), no GKE/Memorystore/Cloud SQL runtime behavior, and no
Checkov exception review. Those remain manual or later-section work per
`design.md`'s "Goals and non-goals" and the proposal's stated non-goals.
