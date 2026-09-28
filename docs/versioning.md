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
| `hashicorp/google` | `~> 6.0` | Verification-required (major); patch-safe within `6.x` |
| `hashicorp/google-beta` | `~> 6.0` | Same as `google`; kept in lockstep |
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
| n8n (`n8n_chart_version`, `oci://ghcr.io/n8n-io/n8n-helm-chart`) | `1.13.0` | Minor-required: run `tests/scripts/chart-values-diff.sh <candidate>`, **and diff `charts/n8n/templates/` between the two tags** (the 1.11.0 to 1.13.0 values diff showed only the pause keys and the `image.tag` default, while the template diff carried the two changes that actually mattered: worker `replicas` ownership and the main task-runner sidecar), then re-run `tests/scripts/check-n8n-chart.sh` against the new default |
| KEDA (`keda_chart_version`, `https://kedacore.github.io/charts`) | `2.20.1` | Minor-required: KEDA's own compatibility matrix pins a Kubernetes-version floor independent of this module's |

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
| Terraform CLI (`TF_VERSION`) | `1.9.8` | **Deliberately not bumped for currency alone.** `AGENTS.md`'s "Known mock provider limitations" section documents validating against this exact floor's stricter `&&`/`\|\|` short-circuit evaluation; bumping it changes what CI proves, not just what CI uses. Treat as verification-required with a specific reason, never a routine bump. |
| tflint (`TFLINT_VERSION`) | `v0.53.0` | Minor-required: re-run `tflint --init` and the full target matrix; a new ruleset version can add a rule that fails a previously-clean target |
| checkov (`bridgecrewio/checkov-action` ref) | `v12.3126.0` (bundles checkov `3.3.20`) | Verification-required: re-run the curated baseline (`tests/scripts/check-checkov.sh`, both passes) and update the referenced verification report if the finding set changes |
| terraform-docs (`TERRAFORM_DOCS_VERSION`) | `v0.24.0` | Patch-safe; re-run `terraform-docs --output-check .` at every target after bumping, since output formatting can shift |

## Keeping this table honest

`tests/scripts/check-version-drift.sh` reports, but never auto-bumps, every
pin above that has a public API to check against. It is not a CI gate by
default (see the weekly `version-drift.yml` workflow); a stale entry here is
still possible between its runs. When you bump a pin by hand, update this
table in the same change.
