# Versioning inventory

Every version this module pins, where it lives, and which tier a bump falls
into. See [`README.md`, Compatibility](../README.md#compatibility) for the
headline provider floors and [`docs/upgrading-n8n.md`](./upgrading-n8n.md) for
upgrade guidance when a bump changes behavior.

## Bump tiers

- **Patch-safe**: bumping the pin alone, with no other change, is expected to
  be a no-op or a strict improvement (bug fixes, security patches). Safe to
  bump on its own PR with a green `terraform test`/`tflint`/`checkov` run.
- **Minor-required**: the pin change alone can shift rendered behavior (a new
  chart default, a new provider resource shape) even though the module's own
  interface does not change. Needs a `CHANGELOG.md` entry explaining what
  moved, even if no module input/output changed.
- **Verification-required**: the pin crosses a boundary that needs a live
  check before merging (a provider major version, a Kubernetes/GKE version
  floor, a database engine major). Needs the live verification recorded in
  `CHANGELOG.md` or a `verification-report.md`, not just a green plan-time
  test.

## Terraform providers (`versions.tf`)

| Provider | Current constraint | Tier to bump |
| --- | --- | --- |
| `hashicorp/google` | `~> 8.0` | Verification-required (major); patch-safe within `8.x`. Moved from `~> 6.23` after the 7.0 and 8.0 upgrade guides were checked against the module's resources and `docs/build-time-decisions.md`'s provider claims were re-verified against `v8.7.0`. The features that set the old floor (`google_sql_user.password_wo`/`password_wo_version` from 6.23.0, `google_container_cluster.secret_manager_config` from 6.1) exist in 8.x too |
| `hashicorp/google-beta` | `~> 8.0` | Same as `google`; kept in lockstep |
| `hashicorp/kubernetes` | `~> 3.0` | Verification-required (major); patch-safe within `3.x` |
| `hashicorp/helm` | `~> 3.0` | Verification-required (major); patch-safe within `3.x` |
| `gavinbunney/kubectl` | `~> 1.14` | Minor-required: this provider applies the raw Ingress-support CRs (`BackendConfig`/`FrontendConfig`/`ManagedCertificate`); verify `kubectl_manifest` behavior is unchanged before bumping |
| `hashicorp/tls` | `~> 4.0` | Patch-safe within `4.x`; verification-required across a major |
| `hashicorp/random` | `~> 3.0` | Patch-safe within `3.x` |
| `hashicorp/time` | `~> 0.14` | Patch-safe: additive-only upstream, see its own CHANGELOG before assuming a 0.x bump is safe |

`modules/controllers/versions.tf` pins `kubernetes`/`helm` independently and
must move in lockstep with the root pins above; `terraform test` in both
locations catches drift, but nothing enforces the two files stay textually
identical.

## Application and controller charts (`variables.tf`)

| Chart | Default (`variables.tf`) | Tier to bump |
| --- | --- | --- |
| n8n (`n8n_chart_version`, `oci://ghcr.io/n8n-io/n8n-helm-chart`) | `1.15.0` | Minor-required: run `tests/scripts/chart-values-diff.sh <candidate>`, **and diff `charts/n8n/templates/` between the two tags** (the 1.11.0 to 1.13.0 values diff showed only the pause keys and the `image.tag` default, while the template diff carried the two changes that actually mattered: worker `replicas` ownership and the main task-runner sidecar; 1.13.0 to 1.14.0 renamed the chart-rendered `WEBHOOK_URL` to `N8N_WEBHOOK_URL` without a release-note entry; 1.14.0 to 1.15.0 renamed the chart-rendered `DB_POSTGRESDB_SSL` to `DB_POSTGRESDB_SSL_ENABLED`, duplicating the module's own entry, which only `check-n8n-chart.sh` caught), then re-run `tests/scripts/check-n8n-chart.sh` against the new default |
| KEDA (`keda_chart_version`, `https://kedacore.github.io/charts`) | `2.21.0` | Minor-required: KEDA's own compatibility matrix pins a Kubernetes-version window independent of this module's (KEDA 2.21 is tested on Kubernetes v1.34 to v1.36, 2.20 on v1.33 to v1.35; <https://keda.sh/docs/2.21/operate/cluster/>). Read the release's "Before upgrading" notes for breaking changes to scalers and authentication, then check them against `keda.tf`, which uses only `secretTargetRef`. Verify with a live in-place upgrade of `examples/small` from the previous default and the smoke test with `LOAD_TEST=true` (worker scaling), and record the result in `CHANGELOG.md`; KEDA's tested window is not enforced and does not move this module's own Kubernetes floor, so the row stays Minor-required |

## Database (`variables_gcp.tf`)

| Setting | Default | Tier to bump |
| --- | --- | --- |
| `postgres_version` | `POSTGRES_16` | Verification-required (major): this module deliberately stays on `POSTGRES_16`; a major bump needs its own compatibility assessment, not a version-currency pass (see `parity-matrix.md` in the 0.4.0 and 0.5.0 parity changes for why `POSTGRES_18` was excluded both times) |

## GKE version (`variables_gcp.tf`)

Unlike AWS's fixed `kubernetes_version` input, this module tracks GKE's own
release channel rather than pinning a Kubernetes minor directly:

| Setting | Default | Tier to bump |
| --- | --- | --- |
| `gke_release_channel` | `REGULAR` | Verification-required: switching channel changes which Kubernetes minors GKE auto-upgrades the cluster through |
| `gke_min_master_version` | `""` (channel decides) | Verification-required if set to a specific minor: confirm the channel still offers it |

## CI toolchain (`.github/workflows/terraform-tests.yml`)

| Tool | Current pin | Tier to bump |
| --- | --- | --- |
| Terraform CLI (`TF_VERSION`) | `1.16.6` | **Verification-required; bumped with a specific reason, not for currency alone.** A recent release, the same pin as terraform-aws-n8n and terraform-azurerm-n8n. Used by fmt, validate, and tflint, and repeated as the first entry of the `terraform` matrix axis in the `test-root` and `test` jobs; update those entries in the same change (matrix values cannot read `env`). |
| Terraform CLI floor (`terraform` matrix axis) | `1.13.0` | **Tracks `required_version`.** The `test-root` and `test` jobs run every suite on this version as well as on `TF_VERSION`, so the declared minimum stays tested. The floor is `>= 1.13` because `postgres_password_write_only`'s ephemeral variable and write-only argument need 1.11 (see `CHANGELOG.md`, Unreleased), and `terraform test` on 1.12 and older leaks about one provider process per `run` block until the command exits (n8n-io/terraform-google-n8n#30), which 1.13.0 does not. Change it only together with `required_version` in `versions.tf` and in every example under `examples/`. `modules/controllers` and its `examples/direct-use` keep their own `>= 1.9` floor. |
| tflint (`TFLINT_VERSION`) | `v0.64.0` | Minor-required: re-run `tflint --init` and the full target matrix; a new ruleset version can add a rule that fails a previously-clean target |
| checkov (`bridgecrewio/checkov-action` ref) | `v12.3126.0` (bundles checkov `3.3.20`) | Verification-required: re-run the curated baseline (`tests/scripts/check-checkov.sh`, both passes) and update the referenced verification report if the finding set changes |
| terraform-docs (`TERRAFORM_DOCS_VERSION`) | `v0.24.0` | Patch-safe; re-run `terraform-docs --output-check .` at every target after bumping, since output formatting can shift |

## Keeping this table honest

`tests/scripts/check-version-drift.sh` reports, but never auto-bumps, the
provider and chart pins above. A provider counts as drift only when its
latest release falls outside the constraint in the table: `~> 3.0` against
3.3.0 is `OK`, `~> 6.23` against 8.x is `DRIFT`. So `OK` means the
constraint admits the latest release, not that the lock file or any caller
uses it. A constraint the script cannot evaluate (for example a prerelease
constraint) is reported as `ERROR` and makes the script exit 2, like a
failed lookup; prerelease registry releases are skipped, not reported. The
chart pins are exact, so any newer chart release is drift. It does not yet
check the CI toolchain pins
(`TF_VERSION`, `TFLINT_VERSION`, the checkov action ref,
`TERRAFORM_DOCS_VERSION`); compare those against their upstream releases by
hand. It is not a CI gate by
default (see the weekly `version-drift.yml` workflow); a stale entry here is
still possible between its runs. When you bump a pin by hand, update this
table in the same change.

The constraint evaluator (`tests/scripts/lib/constraints.sh`) supports a
narrow grammar: comma-separated `~>`, `>=`, `>`, `<=`, `<`, `!=`, `=` or a
bare version, over numeric `N[.N[.N]]` versions. Terraform's documentation
says an exact constraint (`=` or a bare version) cannot be combined with
other conditions. The evaluator does not enforce that, and accepts
`= 1.2.3, >= 1.0`, as `terraform init` does.
