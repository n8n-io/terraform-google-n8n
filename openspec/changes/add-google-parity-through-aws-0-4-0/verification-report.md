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

## What this report does not verify

No live Google Cloud apply, no live Helm upgrade, no chart rendering (chart
1.10.1's `helm template` output is not yet exercised anywhere in this repo;
task 1.3 adds that), no GKE/Memorystore/Cloud SQL runtime behavior, and no
Checkov exception review. Those remain manual or later-section work per
`design.md`'s "Goals and non-goals" and the proposal's stated non-goals.
