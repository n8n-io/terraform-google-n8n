# Implementation checklist

Each numbered section is one focused implementation iteration, in dependency order. Read `AGENTS.md` and the committed Terraform style/test skills before implementation. Use the contracts in `design.md` and `parity-matrix.md`, not AWS resource names. For each changed input, include its changelog entry and regenerate the affected Terraform reference tables. Run that section's plan/render tests on Terraform 1.9.8 before marking it complete.

`n8n_worker_pools`/`n8n_worker_extra_env` and the CI `TF_VERSION`/`TFLINT_VERSION` bump are explicitly out of scope for this change (see `proposal.md`/`design.md`); do not add tasks for them here.

## 1. Bump provider and chart version pins

- [x] 1.1 Bump `kubernetes` to `~> 3.0` and `time` to `~> 0.14` in `versions.tf`, `modules/controllers/versions.tf`, `modules/controllers/examples/direct-use/versions.tf`/`providers.tf`, and every `examples/*/providers.tf`; verify `terraform init -backend=false` and `terraform validate` succeed at every target with only the expected cosmetic "Deprecated Resource" warnings on unversioned `kubernetes_namespace`/`kubernetes_secret` resources.
- [x] 1.2 Bump the default `n8n_chart_version` from `1.10.1` to `1.11.0` in `variables.tf`; verify `tests/scripts/check-n8n-chart.sh` still renders cleanly and no assertion in `tests/defaults.tftest.hcl` regresses.
- [x] 1.3 Applied `examples/small` (as a gitignored scratch copy, `examples/small-upgrade-test/`) on the prior pins against `sa-deployment`, then `terraform init -upgrade` and `terraform plan`/`apply` on the new pins; verified in `verification-report.md`.
- [x] 1.4 Add a Compatibility subsection to `README.md` listing provider floors, the Kubernetes-provider-3.0 upgrade note (including the "widen your own `~> 2.0` constraint first" caveat), and a link to `docs/versioning.md`; link `docs/versioning.md` from `docs/upgrading-n8n.md`'s opening paragraph. Verify both links resolve and markdownlint (4.6) passes.

## 2. Harden DNS/Kubernetes-name validation

- [x] 2.1 Add a per-label 63-character DNS-1123 check to `n8n_fqdn` (`variables.tf`) and `n8n_additional_domains` (`variables_gcp.tf`), on top of existing whole-string checks; verify valid multi-label hostnames pass, an over-63-character label fails, and `a..b`-shaped/hyphen-boundary labels now fail where they previously passed.
- [x] 2.2 Add the same per-label 63-character bound to `n8n_image_pull_secrets` (`variables.tf`), alongside its existing 253-character total-length check; verify a valid multi-label secret name passes and an over-63-character label fails.
- [x] 2.3 Add a `precondition` on `tls_self_signed_cert.self_signed` (`dns.tf`) rejecting `n8n_fqdn` over 64 characters only when `tls_mode = "self_signed"`; verify a 65-character `n8n_fqdn` fails plan under `self_signed` and still succeeds under `google_managed`/`custom`/`secret`.

## 3. Close the checkov opt-in-resource gap and pin the exporter image

- [x] 3.1 Add `tests/checkov/opt-in.tfvars` setting `redis_exporter_enabled = true`, a local `tests/scripts/check-checkov.sh` running both the default and opt-in passes, and the matching second CI invocation; verify the opt-in pass reaches `kubernetes_deployment_v1.redis_exporter` and fails the job if it does not.
- [x] 3.2 Inventory every finding the opt-in pass surfaces on the exporter; fix on merit where possible (the digest pin in 3.3 covers `CKV_K8S_15`/`CKV_K8S_43`), add a narrowly scoped explained `checkov:skip` for `CKV_K8S_11` only (the documented no-CPU-limit trade at `observability.tf:164-166`), and add `terraform test` assertions pinning the exporter's security context, capabilities, memory limit, image digest, and probes; verify each assertion fails against a deliberately weakened fixture before passing against the real resource, and record the corrected count-0 diagnosis in `AGENTS.md`'s "Static analysis" section.
- [x] 3.3 Resolve and pin `redis_exporter_image`'s digest for the current `v1.90.0` tag (`variables_gcp.tf`); verify the digest independently against the live registry manifest before committing it, and confirm existing tests still pass with the digest appended.

## 4. Add versioning and chart-tooling documentation

- [x] 4.1 Write `docs/versioning.md` inventorying every provider, chart, `postgres_version`, `kubernetes_version`, and CI toolchain pin with its bump tier; verify every pin named in `versions.tf`/`variables.tf`/`variables_gcp.tf`/`.github/workflows/terraform-tests.yml` appears exactly once and it is linked from `AGENTS.md`.
- [x] 4.2 Add `tests/scripts/lib/tf-defaults.sh` (shared "read a variable default" helper), `tests/scripts/check-version-drift.sh`, and a weekly `.github/workflows/version-drift.yml`; verify a local run against the current pins reports zero drift, a deliberately stale pin is reported, and a failed upstream lookup exits nonzero rather than silently passing.
- [x] 4.3 Add `docs/helm-chart-coverage.md` and `tests/scripts/check-helm-chart-coverage.sh`; verify the script fails when the doc's declared version disagrees with `n8n_chart_version`'s default and when a synthetic undocumented `values.yaml` key is introduced.
- [x] 4.4 Add `tests/scripts/chart-values-diff.sh`; verify it runs against the current default and a different candidate version without writing any pin, and document direct invocation (no Taskfile).
- [x] 4.5 Add `docs/istio-ingress.md` covering the `create_ingress = false` contract as `Gateway`/`VirtualService`; verify it reuses `examples/split-ingress`'s route-prefix rules and introduces no new example, input, or output.
- [x] 4.6 Add a `markdownlint` CI job over `README.md`, `AGENTS.md`, and `docs/*.md`, wrapping the generated `terraform-docs` block in disable/restore comments; verify the job passes on the current tree and fails against a deliberately introduced lint violation.

## 5. Bring examples to documentation and passthrough completeness

- [x] 5.1 Add a "Production considerations" README section to every example that lets the module own Cloud SQL and/or GCS (`small`, `medium`, `large`, `cloudflare`, `godaddy`, `split-ingress`, `customer-managed-redis`, `customer-managed-cluster`, `customer-managed-gcs`), naming the deletion/backup/force-destroy knobs and linking `docs/destroy-cleanup.md`'s deletion-protection and CMEK sections; verify `customer-managed-everything` correctly gets no such section and `customer-managed-gcs` gets only the Cloud SQL rows.
- [x] 5.2 Add `postgres_backup_retained_backups`/`postgres_transaction_log_retention_days` as nullable passthrough variables to every example from 5.1 that lacks them; verify each example's `tests/defaults.tftest.hcl` asserts both at default (`null`) and with an explicit value, and each example's README reference table is regenerated.
- [x] 5.3 Add `n8n_additional_domains` as a passthrough (default `[]`) to `small`, `medium`, `large`, `customer-managed-cluster`, `customer-managed-redis`, `customer-managed-gcs`, and `customer-managed-everything`; verify each example's test asserts the default and a one-alias case, and `split-ingress` is deliberately excluded.
- [x] 5.4 Document in `examples/cloudflare/README.md` and `examples/godaddy/README.md` why neither passes through `n8n_additional_domains`; verify the explanation names the actual mechanism (Cloudflare `cert-manager` `dnsNames = [var.n8n_fqdn]`, GoDaddy single A-record; the module cannot add SANs to a certificate it did not issue).
- [x] 5.5 Add `scripts/check-example-parity.sh` diffing every example's `variables.tf` names against `examples/small`'s with a per-example allowlist, plus the README "Production considerations" presence check; verify it runs clean against the post-5.1 through 5.4 tree and fails against a deliberately introduced one-sided variable and a deliberately removed section.

## 6. Keep the contributor surface in step

- [x] 6.1 Add every new script to `AGENTS.md`'s local development loop and `tests/scripts/README.md`; verify the documented target list still equals the CI matrix and each new script's invocation is by path (no Taskfile).
- [x] 6.2 Write the `CHANGELOG.md` `[Unreleased]` entries: a **BREAKING** Kubernetes-provider entry with "what moves on apply" framing, `time`/chart bumps, each tightened validation framed as "always rejected downstream, now rejected at plan", the exporter digest pin, and each new doc/script; verify every `Port`/`Adapt` row in `parity-matrix.md` has a corresponding entry and every `Exclude`/`Omit` row has none.

## 7. Run final automated acceptance

- [x] 7.1 Run `terraform fmt -check -recursive`, backend-free init, validate, `terraform test -verbose`, `tflint`, and `terraform-docs --output-check .` across the root, every example, and both controller targets on Terraform 1.9.8 (ran on local `1.16.1`; see `verification-report.md`'s "Known deviations"); verify every target passes with only GoDaddy stub credentials where required.
- [x] 7.2 Run `tests/scripts/check-n8n-chart.sh`, `tests/scripts/check-checkov.sh` (default and opt-in passes), the new `check-version-drift.sh`/`check-helm-chart-coverage.sh`/`chart-values-diff.sh`/`check-example-parity.sh` scripts, and the markdownlint job locally; verify a clean run and that each script fails against its own documented negative fixture.
- [x] 7.3 Review the diff against `parity-matrix.md`; verify every `Port`/`Adapt` row maps to an implemented change, every `Exclude`/`Omit`/`Existing` row has no corresponding code change beyond the annotations the matrix itself calls for, and no unrelated implementation, leaked secret, or unverified digest/version claim is included. Write `verification-report.md` recording the 1.3 upgrade-plan output and the final acceptance run.
