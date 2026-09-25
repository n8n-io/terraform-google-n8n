# Verification report

Implementation of `add-google-parity-through-aws-0-5-0`, run against this
repository at HEAD. Environment: Terraform `1.16.1` (CLI), `checkov` `3.3.17`,
`tflint` `0.64.0`, `terraform-docs` `v0.24.0`, `helm` `v4.3.0`,
`markdownlint-cli2` `0.23.2`. No 1.9.8 Terraform CLI was available locally;
see the caveat under "Known deviations" below.

## Section 1: Version and chart bumps

- **1.1** Bumped `kubernetes` to `~> 3.0` and `time` to `~> 0.14` in
  `versions.tf`, `modules/controllers/versions.tf`, both `direct-use`
  files, and every `examples/*/versions.tf`. `terraform init -backend=false`
  + `terraform validate` at every one of the 13 targets: all `Success`, with
  only the predicted cosmetic "Deprecated Resource" warnings (9 unversioned
  `kubernetes_secret`/`kubernetes_namespace` resources).
- **1.2** Bumped default `n8n_chart_version` to `1.11.0` in `variables.tf`
  and the hardcoded `CHART_VERSION` inside `tests/scripts/check-n8n-chart.sh`
  (a real gap the script itself had: it did not read the module's own
  default). Re-ran the script against `1.11.0`: all checks pass, confirming
  the chart's two 1.11.0 behavior changes are inert here.
- **1.3 (live-verified)** Live-verified the in-place upgrade against
  project `sa-deployment`, host `n8n-k8s-upgrade-test.cmifro.com` (Cloudflare
  A-record pointed at the LB static IP, `tls_mode = google_managed`), using
  a gitignored scratch copy of `examples/small` (`examples/small-upgrade-test/`,
  tracked files only, added to `.git/info/exclude`, removed after teardown).
  Baseline apply on the prior pins (`kubernetes ~> 2.0`, chart `1.10.1`,
  resolved `kubernetes` provider `2.38.0`): **46 to add, 0 to change, 0 to
  destroy**, applied clean (all pods `Running`, `helm_release` `deployed`
  at chart `1.10.1`) after two retries unrelated to this change: an
  environmental Helm atomic-install timeout on the first attempt, and a
  license-gated crash (`S3 binary data storage requires a valid license`)
  until a real Enterprise license key was supplied. Then `terraform init
  -upgrade` (resolved `kubernetes` provider `3.2.1`) and `terraform plan`:
  **exactly** `Plan: 0 to add, 1 to change, 0 to destroy`, only
  `helm_release.n8n`'s `version` attribute (`1.10.1` → `1.11.0`), with only
  the predicted cosmetic deprecation warnings and no action on any
  `kubernetes_namespace`/`kubernetes_secret`/other Kubernetes-managed
  resource. Applied the upgrade: **0 added, 1 changed, 0 destroyed**,
  chart rolled to `1.11.0` (revision 2, `deployed`), all pods `Running`
  post-rollout, and the immediately following `terraform plan` reported
  "No changes." Teardown: flipped `gke_deletion_protection`/
  `postgres_deletion_protection`/`gcs_force_destroy` in one apply, then
  `terraform destroy`. The GKE Ingress object took longer than the first
  destroy invocation's patience to fully deprogram (`Error: Ingress
  (n8n/n8n-ingress) still exists`); a second `terraform destroy` invocation
  completed the rest (**38 destroyed**) with **no PSA-peering stall this
  time** (`google_service_networking_connection.psa` and the VPC network
  both destroyed cleanly). `terraform state list` confirmed empty; an
  out-of-band `gcloud`/`gcloud storage` sweep across GKE, Cloud SQL, Redis,
  networks, addresses, buckets, and service accounts filtered by the
  `k8sup` prefix found zero leftovers. The Cloudflare A-record was deleted
  and the local `kubectl` context/cluster/user entries removed.
- **1.4** Added a "Compatibility" subsection extension to `README.md`
  (a "Compatibility" subsection already existed from a prior change) with
  the Kubernetes-provider-3.0 note and `docs/versioning.md` link; linked
  `docs/versioning.md` from `docs/upgrading-n8n.md`'s opening paragraph.

## Section 2: DNS/Kubernetes-name validation hardening

- Added per-label 63-character DNS-1123 checks to `n8n_fqdn`,
  `n8n_additional_domains`, and `n8n_image_pull_secrets` (additive to
  existing whole-string checks). Added a `precondition` on
  `tls_self_signed_cert.self_signed` bounding `n8n_fqdn` to 64 characters
  under `tls_mode = self_signed` only.
- Added 12 new `terraform test` cases across `tests/ingress_ownership.tftest.hcl`
  (fqdn/additional_domains per-label accept/reject + self-signed CN
  accept/reject) and `tests/application_portability.tftest.hcl`
  (image_pull_secrets per-label accept/reject). Root suite: **484 passed, 0
  failed** (up from the pre-change 470; all 14 new cases pass, no
  regression).

## Section 3: checkov opt-in coverage + exporter digest

- Added `tests/checkov/opt-in.tfvars`, `tests/scripts/check-checkov.sh`
  (two-pass runner with a resource-reachability check), and the
  `checkov-opt-in` CI job.
- Discovered the real checkov root cause during implementation: checkov's
  inline suppression comment (`#checkov:skip=...`) must be **inside** the
  resource block (`start_line < comment_line < end_line`), not immediately
  above it, per checkov 3.3.17's own `base_parser.py`. Verified with an
  isolated repro before and after moving the comment.
- Default checkov pass: **111 passed, 0 failed, 172 skipped**. Opt-in pass
  (redis_exporter enabled): **139 passed, 0 failed, 172 skipped**, with the
  reachability check confirming both `kubernetes_deployment_v1.redis_exporter`
  and `kubernetes_service_v1.redis_exporter` were actually evaluated.
  Negative fixture (opt-in tfvars reverted to `false`) correctly fails the
  reachability check.
- Resolved `redis_exporter_image`'s digest live: `docker buildx imagetools
  inspect oliver006/redis_exporter:v1.90.0` →
  `sha256:a129504e65b87c54f79bc92f1afc403475e8ff646a3d7512de469904ceddf986`
  (multi-arch index). Verified independently, not copied from the AWS
  changelog text (it happened to match, since both pin the same public
  tag).
- Added 3 new `terraform test` assertions in `tests/redis_observability.tftest.hcl`
  pinning the exporter's image (digest-inclusive), plus digest-format
  accept/reject cases. Redis observability suite: **10 passed, 0 failed**.

## Section 4: Docs/tooling ports

- `docs/versioning.md`, `tests/scripts/lib/tf-defaults.sh`,
  `tests/scripts/check-version-drift.sh` + `.github/workflows/version-drift.yml`,
  `docs/helm-chart-coverage.md` + `tests/scripts/check-helm-chart-coverage.sh`,
  `tests/scripts/chart-values-diff.sh`, `docs/istio-ingress.md`, and the
  `markdownlint` CI job + `.markdownlint.json`.
- `check-version-drift.sh` run live: correctly reports 10 pins behind
  upstream (every `~>`-constrained provider resolves below the true
  latest, by design; the n8n chart is one minor behind at `1.11.0` vs
  upstream `1.12.0`; KEDA one patch behind), 0 lookup failures. GHCR
  anonymous-token tag listing, Terraform Registry API, and the KEDA Helm
  repo were all verified reachable and parseable live.
- `check-helm-chart-coverage.sh` run live against chart `1.11.0`: passes;
  verified with two negative fixtures (version mismatch, missing key row)
  that it correctly fails.
- `chart-values-diff.sh 1.12.0` run live: succeeds, prints a real diff
  (image tag default change, task-runner comment change) confirmed against
  upstream. Failure path verified with a nonexistent version (exit 1).
- `markdownlint-cli2` run against `README.md`/`AGENTS.md`/`docs/*.md`:
  **0 issues**. Found and fixed two real pre-existing defects while wiring
  this up: an escaped-pipe bug in `docs/versioning.md`'s own table
  (literal `||` inside a table cell, parsed as two extra columns) and
  three missing-blank-line-around-fence violations in `README.md`.
- `actionlint` against both `.github/workflows/*.yml`: clean.

## Section 5: Example parity

- Delivered via 5 parallel subagent batches (2 examples each), each
  independently verified with `terraform init`/`validate`/`terraform-docs`/`terraform test`.
- **Recovery note:** during negative-fixture testing of
  `scripts/check-example-parity.sh`, a `git checkout --` intended to revert
  a temporary test variable instead reverted the entirety of
  `examples/medium/variables.tf` to its pre-change committed state
  (destroying the subagent's real work). Detected immediately via the
  parity script's own next run, diagnosed via `main.tf`'s dangling variable
  references, and manually re-added the three lost variable blocks.
  Re-verified with `terraform validate`/`test`/`terraform-docs
  --output-check`: all pass, `git diff` confirms the file matches its
  pre-incident state. No other file was affected (the command only
  targeted that one path).
- `scripts/check-example-parity.sh` run live against the final tree, after
  building complete (not truncated) per-example variable-name allowlists
  from direct extraction rather than partial `grep` views: **passes**,
  confirming every example's variable set matches `examples/small`'s
  within its documented allowlist, and every Cloud-SQL/GCS-owning example
  has a "Production considerations" section. Negative fixture (one-sided
  variable addition) correctly fails.

## Section 6: Contributor surface

- `AGENTS.md`: extended "Static analysis" (checkov-opt-in, markdownlint)
  and "Clear documentation" (markdownlint rule-disable rationale) sections;
  extended the local development loop with the two new script/lint
  commands.
- `tests/scripts/README.md`: added sections for `check-checkov.sh` and the
  three version-currency scripts.
- `CHANGELOG.md`: added entries under `### Added` (tooling/docs/examples),
  `### Changed` (breaking provider/chart bumps), `### Fixed` (validation
  hardening), and a new `### Security` section (digest pin), all within
  `## [Unreleased]`.

## Section 7: Final acceptance

- **Root**: `terraform fmt -check -recursive` clean; `terraform validate`
  clean (cosmetic deprecation warnings only); `terraform test` **484
  passed, 0 failed**; `tflint --format compact` clean; `terraform-docs
  --output-check .` up to date.
- **All 10 examples** (`small`, `medium`, `large`, `cloudflare`, `godaddy`,
  `split-ingress`, `customer-managed-cluster`, `customer-managed-redis`,
  `customer-managed-gcs`, `customer-managed-everything`): validate/test/tflint/docs
  all clean.
- **`modules/controllers` and its `examples/direct-use`**: validate/test
  clean. `terraform-docs --output-check` initially failed for both (the
  provider-bump README regeneration from section 1 had never been run for
  these two targets); regenerated live, re-verified clean, diff confirmed
  limited to the expected `~> 2.0` → `~> 3.0` table row.
- `tests/scripts/check-checkov.sh`, `check-version-drift.sh`,
  `check-helm-chart-coverage.sh`, `check-n8n-chart.sh`,
  `scripts/check-example-parity.sh`, and `markdownlint-cli2` all re-run
  clean as a final combined pass after every fix above.

## Review against `parity-matrix.md`

Every `Port`/`Adapt` row has a corresponding implemented change above.
Every `Exclude`/`Omit` row has no corresponding code change. No AWS-only
flag, worker-pools code, or unrelated implementation was introduced. No
secret is committed (the opt-in checkov fixture and every test fixture use
placeholder values, e.g. `"checkov-fixture-not-a-real-license-key"`).

## Known deviations from the local-loop bar in `AGENTS.md`

- Local Terraform CLI is `1.16.1`; CI pins `1.9.8`. `AGENTS.md` warns that
  1.9.x evaluates `&&`/`||`/nullable-object-access more strictly than newer
  CLIs. Every new/changed `validation`/`precondition` in this change uses
  only patterns `AGENTS.md` already documents as CI-1.9.x-safe (`can(regex(...))`,
  ternary nesting rather than `||` short-circuiting, `try(...)` around
  possibly-empty-list access), but this was not re-verified on an actual
  1.9.8 binary, since none was available in this environment.
- Local `tflint` is `0.64.0`; CI pins `v0.53.0`. Ran clean locally at the
  newer version; not cross-checked against the older pin.

## Outstanding item

None. All `tasks.md` items across sections 1 through 7, including 1.3,
are complete and verified as above.
