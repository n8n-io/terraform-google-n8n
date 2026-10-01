# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this
repository. Human contributors should also find this useful; it explains *what*
this module is and *what bar* it is held to.

## What this repo is

`terraform-google-n8n` is a Terraform module that deploys a **production-grade,
multi-main [n8n Enterprise](https://n8n.io) installation on Google Cloud**. A
single `terraform apply` brings up the full stack:

- **Google Kubernetes Engine (GKE)** regional cluster with a managed node pool
  sized for the multi-main workload (default `e2-standard-4`, autoscaled per
  zone) and native node-pool autoscaling.
- **Multiple n8n main pods** plus dedicated **worker pods** (queue mode), the
  Enterprise multi-main topology.
- **Cloud SQL for PostgreSQL** as the n8n database, over Private Service Access.
- **Memorystore for Redis** for the Bull queue backing the workers, over Private
  Service Access.
- **Google Cloud Storage** for shared binary / file storage, reached through
  n8n's S3-compatible binary-data driver via an HMAC key.
- **Workload Identity** so n8n pods authenticate to Google Cloud APIs (Cloud SQL,
  etc.) without static service-account keys.
- **Native GKE Ingress** (Google Cloud L7 load balancer) plus **KEDA** for
  queue-driven worker scaling. GKE provides node autoscaling and the load
  balancer controller natively, so there is no separate controller to install.
- **TLS + DNS** automated end-to-end. `tls_mode = "google_managed"` (default)
  provisions a ManagedCertificate; the module can also manage a Cloud DNS
  A-record, or you can bring your own DNS (Cloudflare and GoDaddy examples show
  this). Other `tls_mode` values (`secret`, `custom`, `self_signed`) cover
  cert-manager, bring-your-own-PEM, and pre-DNS smoke testing.

An **n8n Enterprise license credential** is required (the module does not
provision a community-edition deployment): supply exactly one of
`var.n8n_license_key`, `var.n8n_license_key_secret_ref` (a caller-managed
Secret holding the key), or, for air-gapped and egress-restricted clusters,
`var.n8n_license_cert_secret_ref` (a caller-managed Secret holding an
offline license certificate rendered as `N8N_LICENSE_CERT` through
`config.extraEnv`, never through the chart's `license.existingSecret`
block - see "Offline license activation" in README.md).

The module **creates its own VPC**. Reference deployments are organized as
**three sizing tiers**: [`examples/small/`](./examples/small/) is the smallest
viable production deployment using module defaults;
[`examples/medium/`](./examples/medium/) and [`examples/large/`](./examples/large/)
are progressively scaled-up reference architectures. Two **DNS-variant examples**
at `small` sizing, [`examples/cloudflare/`](./examples/cloudflare/) and
[`examples/godaddy/`](./examples/godaddy/), swap the DNS provider for the
A-record and TLS wiring.

### Architecture at a glance

```
   ┌── Cloud DNS (optional) ──┐
   │  or Cloudflare/GoDaddy   │
   │                          ▼
   user ──► GKE Ingress (L7 LB) ──► GKE ──► n8n mains ──► Cloud SQL (Postgres)
                                        │           │
                                        │           └──► Memorystore (Redis) ◄── workers (KEDA-scaled)
                                        │
                                        └──► GCS (Workload Identity + HMAC) for binary data
```

### File layout

The module follows the [standard module
structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
expected by the Terraform Registry:

| File / dir                        | Purpose                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| `versions.tf`                     | `required_version` plus `required_providers` only.          |
| `variables.tf` / `variables_gcp.tf` | All inputs, with `description`, `type`, and `validation`. |
| `outputs.tf`                      | All outputs, with `description` and `sensitive` where needed. |
| `locals.tf`                       | Shared locals (labels, naming, derived values).             |
| `network.tf` / `gke.tf` / `cloudsql.tf` / `memorystore.tf` / `gcs.tf` / `kms.tf` / `workload_identity.tf` / `org_policy.tf` / `dns.tf` / `n8n.tf` / `crds.tf` / `keda.tf` / `controllers.tf` / `scaling.tf` | One file per logical concern. `dns.tf` owns Cloud DNS record management; `kms.tf` owns the shared Cloud KMS key ring and each service's create-or-reference CMEK key (Cloud SQL today; later sections add Memorystore and GCS to the same ring); `controllers.tf` invokes `modules/controllers` (KEDA + the optional PD StorageClass); `keda.tf` only wires the Redis `TriggerAuthentication` KEDA needs. Do **not** split by DNS provider. |
| `modules/controllers/`            | Public submodule owning the KEDA Helm release and the optional pd-balanced `StorageClass`; directly consumable, with its own `versions.tf`/`variables.tf`/`outputs.tf`/`README.md`/`tests/`/`examples/direct-use`. |
| `README.md`                       | Human entry point; the `<!-- BEGIN_TF_DOCS -->` block is generated by `terraform-docs`. |
| `LICENSE`                         | Required for registry publication.                          |
| `examples/small/`                 | Smallest viable production deployment using module defaults (creates the VPC). |
| `examples/medium/`                | Scaled-up reference architecture (creates the VPC).         |
| `examples/large/`                 | Further scaled-up reference architecture (creates the VPC). |
| `examples/cloudflare/`            | DNS-variant of `small` using Cloudflare DNS + cert-manager. |
| `examples/godaddy/`               | DNS-variant of `small` using GoDaddy DNS.                   |
| `examples/customer-managed-cluster/`, `examples/customer-managed-redis/`, `examples/customer-managed-gcs/`, `examples/customer-managed-everything/` | Ownership-boundary examples: an existing GKE cluster, external Redis, an existing GCS bucket, and every layer customer-managed, respectively. None creates a VPC. |
| `examples/worker-pools/`          | EARLY ALPHA: labelled worker pools (`n8n_worker_pools`), sizing-equivalent to `small` apart from `gke_node_max_per_zone`. Creates the VPC. |
| `tests/*.tftest.hcl`              | `terraform test` plan-time tests with mocked providers.     |
| `tests/scripts/smoke-test.sh`     | Post-`apply` smoke test for live deployments.               |
| `docs/`                           | Long-form supplementary docs: `customer-managed-infrastructure.md` (ownership matrix and security boundary), `post-deployment.md`, `destroy-cleanup.md`, `troubleshooting.md`. |
| `.github/workflows/`              | CI: fmt, terraform-docs, validate, test, tflint, chart-render, checkov. |
| `.github/CODEOWNERS` / `CONTRIBUTORS` | Default reviewers and the current maintainer list; keep the two in sync. |
| `Taskfile.yml`                    | Optional [`task`](https://taskfile.dev) wrapper around the local development loop below (`task ci`). Its `EXAMPLES` list must match the CI job matrices. Not a CI dependency. |
| `scripts/check-variable-banners.sh` | Local-only check (`task banners`) that every `variable`/`output` in `variables.tf`, `variables_gcp.tf`, and `outputs.tf` sits under a `# ── Section ──` banner and that the banner list matches the script's expected order. Update its banner arrays when adding, renaming, or reordering a section. |
| `scripts/check-example-parity.sh` | Local-only check (`task example-parity`) that each example's variable set matches `examples/small` within its allowlist. Must stay compatible with the bash 3.2 macOS ships (no `declare -A`). |

## Quality bar: HashiCorp Terraform Registry & Partner Premier Tier

This module targets the quality criteria HashiCorp publishes for partner
modules in the Terraform Registry, specifically the
[Partner Premier Tier](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
and the broader [Terraform partnerships
guidelines](https://developer.hashicorp.com/terraform/docs/partnerships).

> Module quality is ensured through a varied set of standards focused on
> HashiCorp-defined, best-in-class infrastructure as code principles. This
> includes:
>
> - Successfully passing TFLint, Checkov, or another static code analysis tool
>   and reporting the result to HashiCorp
> - Traditional unit and integration testing via Terraform test
> - Adherence to Terraform's official naming conventions
> - Clear module documentation
> - Inclusion of all standard module files

Concretely, in this repo:

### 1. Static analysis (TFLint + Checkov)

`.github/workflows/terraform-tests.yml` runs both on every PR and push to `main`:

- **`terraform fmt -check -recursive`** for canonical formatting.
- **`terraform validate`** against the module root, every application/DNS/
  ownership example, the `modules/controllers` submodule, and its own
  `examples/direct-use`, via the CI matrix (see the target list in
  `.github/workflows/terraform-tests.yml`'s `validate`/`test`/`tflint` jobs;
  the same list drives the local loop below).
- **`tflint`** against every target in that same matrix, with the ruleset
  initialized via `tflint --init`.
- **`checkov`** (`bridgecrewio/checkov-action@v12.3126.0`, pinned to Checkov
  `3.3.20`) against the Terraform framework, repository root, at the
  **default** tfvars. `soft_fail` is `false`: an unapproved new finding fails
  the job. See
  `openspec/changes/archive/2026-09-14-add-google-parity-through-aws-0-4-0/verification-report.md`
  for the curated baseline this was flipped against. **When you add new
  resources, do not regress curated findings; prefer fixing them over adding
  suppressions.**
- **`checkov-opt-in`** runs a second pass against
  `tests/checkov/opt-in.tfvars`, which flips on every switch that gates a
  resource defaulting to count 0. **checkov answers every check on a count-0
  resource `UNKNOWN`, not `FAILED`, and drops it from the report entirely**;
  a resource behind a default-`false` toggle (e.g. `redis_exporter_enabled`)
  is otherwise invisible to both the default pass and any earlier baseline
  review that scanned only at defaults. `tests/scripts/check-checkov.sh`
  runs both passes and additionally verifies the opt-in pass actually
  *evaluated* each resource named in its own `REQUIRED_OPT_IN_RESOURCES`
  list, not just that the run exited 0 - add a resource to both that list
  and `tests/checkov/opt-in.tfvars` when you add a new count-gated resource,
  or this check silently stops proving anything for it. The opt-in pass runs
  with `--skip-path examples` and its reachability check accepts only
  root-module addresses (no `module.n8n.` prefix) with at least one passed
  or failed check (a skipped check alone does not count), so it covers count-gated
  resources in the root module only; a count-gated resource inside an
  example is not unblinded by this pass.
- **`tests/scripts/check-n8n-chart.sh`** (`chart-render` job) renders the
  pinned n8n Helm chart with a synthetic values fixture and asserts on the
  output, using a pinned Helm CLI version. No credentials, no cluster.

### 2. Unit + integration tests via `terraform test`

- `tests/defaults.tftest.hcl` is the canonical plan-time test suite. It uses
  `mock_provider` for `google`, `kubernetes`, `kubectl`, `helm`,
  `random`, and `time`. The module has no data sources to override, so the
  suite runs **without Google Cloud credentials** and is safe to run in CI.
- CI runs the root suite **one job per `tests/*.tftest.hcl` file**
  (`test-root` job, `terraform test -filter=<file>`, matrix generated from
  the filesystem so a new file is picked up automatically) and without
  `-verbose`. One serial job with full plan output for 500 runs took 43
  minutes and starved the runner until a mock provider missed Terraform's
  fixed 60 s plugin start timeout (`timeout while waiting for plugin to
  start`), failing an unrelated run. Keep `-verbose` for the local loop.
- Each example, the `modules/controllers` submodule, and its own
  `examples/direct-use` has its own `tests/defaults.tftest.hcl` that
  exercises it end-to-end with the same mocking strategy, catching wiring
  mistakes between the module (or submodule) and a realistic caller.
- `tests/scripts/smoke-test.sh` is the **integration / post-apply** check used
  against a real cluster, kept out of CI on purpose (it needs live Google Cloud
  credentials and an applied stack).

When you add a feature, add an `assert` for it in the relevant `.tftest.hcl`
file. Use `command = plan` unless you specifically need apply semantics.

#### Known mock provider limitations

- **`helm_release.values` is unknown at plan time.** The `values` argument is
  a locally-computed `yamlencode()` block, but because it belongs to a
  resource that depends on `kubernetes_namespace` (whose attributes are
  `(known after apply)` under the mock provider), the whole resource,
  including its inputs, is deferred. You cannot assert on Helm values
  content in `command = plan` tests.
- **Computed nested blocks are empty under mocks.** For example
  `google_container_cluster.master_auth` is an empty list under the mock
  provider, so `master_auth[0].cluster_ca_certificate` must be guarded with
  `try(..., null)` in `outputs.tf` (it is). Assert at the variable-contract
  level when a value is only known after apply.
- **A parent module's `run` blocks cannot address a child module's internal
  resources**, only its declared outputs (e.g. `module.controllers.foo` where
  `foo` is an output, not `module.controllers.helm_release.keda[0]`). When a
  root-level test needs to assert on something a submodule (`modules/*`)
  creates, add an output for it on the submodule and assert on that output
  from the root test; keep the submodule's own resource-level assertions
  (provisioner, reclaim policy, etc.) in the submodule's own `tests/`.
- **A variable `validation` block failing aborts the run before `check`
  blocks are evaluated.** If a `run` sets an invalid value for variable A
  (caught by A's own `validation`) while also triggering an unrelated `check`
  warning, only list `var.A` in `expect_failures`; the `check` never runs, so
  listing it too fails with "was expected to report an error but did not".
  Conversely, when a variable's own validation still *passes* but a `check`
  block fires anyway (e.g. an opposite-path ignored-input diagnostic keyed off
  a *different* variable), the `check` still evaluates normally and must be
  listed in `expect_failures` to avoid an unrelated test failure.
- **Two `variable` blocks cannot each reference the other in their own
  `validation` condition** (e.g. an exactly-one-of-two-required check
  duplicated symmetrically on both variables): Terraform reports `Cycle: var.A
  (validation), var.B (validation)`. Put the cross-variable condition on
  exactly one of the two variables.
- **A resource attribute that depends on another managed resource's computed
  output (e.g. `encryption_key_name = google_kms_crypto_key.x[0].id`) is
  unknown at `command = plan` time**, even though the referencing resource's
  own attributes otherwise look like plan-known strings in the error message.
  Assert `!= null` is not enough either (still unknown); assert only resource
  counts/other plan-known attributes, or drop the assertion and note that it
  needs a real `apply`.

- **The pinned n8n Helm chart renders `imagePullSecrets` nowhere** (not on the
  pod spec, not on the ServiceAccount it creates), so a private image registry
  has no way in through chart values alone. The fix is to take over the
  ServiceAccount only when there is something to attach
  (`length(var.n8n_image_pull_secrets) > 0`), under a **different name** than
  the chart's own default, and flip the chart's `serviceAccount.create` to
  `false` while pointing `serviceAccount.name` at the module-managed one. A
  shared name would collide with the account Helm still owns on the apply
  that first sets the pull secrets (`serviceaccounts "x" already exists`).
  Carry over any annotation the chart's own account would have had (e.g. a
  Workload Identity binding), since ownership moving off the chart also moves
  responsibility for that annotation.

- **A `dynamic` block whose label matches its own nested attribute name still
  resolves correctly with an explicit `iterator`.** E.g. `kubernetes_ingress_v1`
  `http` rule paths: the `path { path = ..., path_type = ..., backend {...} }`
  block type is itself called `path`, and its own `path` attribute needs the
  loop value. Using the default iterator name (same as the dynamic block's
  label) is legal but reads ambiguously (`path = path.value`); add `iterator =`
  with a distinct name (e.g. `route`) so `path = route.value` is unambiguous at
  the call site. Iterating over the same ownership-neutral list (e.g.
  `local.effective_webhook_route_prefixes`) that a stable output already
  exposes keeps the actual managed `Ingress` and the caller-facing route
  contract from drifting apart.

- **A `terraform test` `run` block that intentionally triggers an unrelated
  `check` warning as a side effect of the variables under test must list that
  check in its own `expect_failures`,** even when the run's actual assertions
  are about something else entirely (e.g. testing that `tls_mode = self_signed`
  omits cert resources when `create_ingress = false` also trips the
  ignored-managed-ingress-tuning `check`). Otherwise the run fails on the
  `check`, not on any `assert` block.

- **A block whose schema repeats as a set (e.g. `google_compute_security_
  policy`'s `rule` block) cannot be indexed (`resource.rule[0]`) in a test
  assertion** ("Block type ... is represented by a set of objects, and set
  elements do not have addressable keys"). Use a `for`/`anytrue` expression
  over the set instead of positional indexing.

- **Every `examples/*` directory needs its own `.terraform-docs.yml`**, not
  just the root's. `terraform-docs` looks for `.terraform-docs.yml` in the
  current working directory only (no upward search), so a new example with
  no local config prints the CLI help instead of rendering/checking anything,
  and both a plain `terraform-docs .` and `terraform-docs --output-check .`
  exit 0 either way, so a missing config silently no-ops instead of failing.
  Copy an existing example's `.terraform-docs.yml` (they are all identical:
  `formatter: markdown table`, inject between the `BEGIN_TF_DOCS`/`END_TF_DOCS`
  markers, `lockfile: false`) into every new example directory, and add the new
  example to the `docs`, `validate`, `test`, and `tflint` job matrices in
  `.github/workflows/terraform-tests.yml`, or CI silently skips it entirely.

- **A parent example's test can only prove a fully customer-managed
  composition creates no module-owned resource through the module's own
  outputs, not by asserting on the module's internal resource addresses**
  (same addressing limitation as the controller submodule, above). Assert
  that each effective output resolves to the caller-supplied reference (e.g.
  `module.n8n.gcs_bucket_name == var.existing_gcs_bucket_name`) rather than
  trying to assert a resource count inside `module.n8n`.

- **A `# tflint-ignore: <rule>` comment only suppresses the finding when it is
  the single line immediately above the flagged block**, with no trailing
  `-- explanation` text appended on the same line. A multi-line explanation is
  fine as long as the `tflint-ignore` directive itself is its own last comment
  line before the declaration; put prose on preceding lines instead. Used for
  an attestation variable (e.g. `existing_gke_prerequisites_attestation`)
  whose only reference is its own `validation` block condition: tflint's
  `terraform_unused_declarations` rule does not count that self-reference as
  a use, which is a genuine false positive for the ownership model's
  attestation inputs.

- **Checkov's `CKV_GCP_73` (Cloud Armor log4j2/CVE-2021-44228 protection)
  requires a `rule` block whose `match.expr.expression` is exactly
  `evaluatePreconfiguredExpr('cve-canary')` (or the `evaluatePreconfiguredWaf`
  variant) with a non-`allow` action and no `preview = true`.** Any new
  `google_compute_security_policy` resource needs this rule alongside its
  own allow/deny rules, or the curated Checkov baseline regresses. Test
  assertions that iterate a security policy's `rule` set must guard
  `match[0].config` before indexing into it, since this rule uses
  `match.expr` instead of `match.config` (see the `for`/`anytrue` guidance
  above). Guard with `try(...)`, not `length(...) > 0 && ...[0]`: Terraform
  does not short-circuit `&&`, so the CI-pinned 1.9.x still evaluates the
  empty-list index and fails the run.

- **CI pins Terraform 1.9.x (`TF_VERSION` in
  `.github/workflows/terraform-tests.yml`); validate every expression against
  that version's stricter evaluation, not just a newer local CLI.** Two
  behaviors bite in particular, because Terraform never short-circuits `&&`
  and `||`: (1) `contains(list, var.x)` errors when `var.x` is null, so a
  nullable variable's validation must use `var.x == null ? true :
  contains(...)` rather than `var.x == null || contains(...)`; (2) indexing
  a possibly-empty list on one side of `&&` errors even when the other side
  is false, so wrap the whole access in `try(..., false)`; (3) reading an
  attribute off a nullable object variable or `for`-loop element (e.g.
  `var.x == null || var.x.name != ""`, or `v.config_map == null ||
  v.config_map.default_mode == null`) errors the same way, so nest ternaries
  instead: `var.x == null ? true : (var.x.name != "")`. Newer CLIs (1.13+)
  tolerate all three spellings, which makes a green local run misleading; run
  the loop with the CI-pinned version when touching validations or test
  asserts. This bit `n8n_credentials_overwrite_secret_ref`, `n8n_extra_volumes`,
  `n8n_dns_config`'s `ndots` check, and a `redis_observability.tftest.hcl`
  assertion (`add-google-parity-through-aws-0-4-0`, section 24.1), none of
  which failed under a newer local Terraform.

- **A `terraform test` `assert` condition can reference module `local.*` values
  directly** (not just resource/output attributes), which is the way to test
  a pure-input-derived local (e.g. topology selection, a rollout `strategy`
  map) that plan-time mock limitations keep out of `helm_release.values`.
  However, `==` between two object/map-typed expressions (e.g.
  `local.x == { type = "Recreate" }` or `local.x == {}`) only emits a
  "LHS and RHS values are of different types" warning and the assertion
  silently fails even when the maps are logically equal; compare via
  `length(keys(local.x)) == 0` for an expected-empty map and
  `try(local.x.type, null) == "Recreate" && length(keys(local.x)) == 1` for an
  expected-single-key map instead of a direct map `==`.

- **An RFC3339 timestamp input can be validated at the variable layer with
  `can(formatdate("YYYY", var.x))`** (any format string works; only whether
  parsing succeeds matters) instead of a hand-rolled regex: `formatdate`
  itself rejects malformed timestamps, non-existent dates (e.g. month 13),
  and non-Zulu/non-RFC3339 strings, and `can(...)` turns that error into a
  clean `false` for a `validation` block. Used for
  `redis_rdb_snapshot_start_time` (`google_redis_instance.persistence_config`).

- **A chart's top-level `strategy` (Deployment rollout strategy) may be read
  by only one role's Deployment template**, even when the chart also renders
  worker/webhook-processor Deployments from the same values file; grep the
  vendored chart's other `deployment-*.yaml` templates for the same values
  path before assuming a shared top-level key changes every role's rollout
  behavior.

- **A test fixture value for a variable validated with `regex("^[0-9a-fA-F]{64}$", ...)` (e.g.
  `n8n_encryption_key`) is easy to miscount by hand into 63 or 65 characters.**
  Generate it instead: `python3 -c "import secrets; print(secrets.token_hex(32))"`.

**Recommended pattern** when end-to-end wiring cannot be tested under mocks:

1. Write `command = plan` assertions at the variable contract level (default
   value, type acceptance, validator rejection).
2. Add a comment in the test file explaining *why* the wiring cannot be
   asserted and *how* to verify it manually (e.g. "run a real `terraform
   plan` from an example root").
3. Do not reach for `command = apply` to work around plan-time unknowns.

### 3. Naming conventions

This module follows the [Terraform module
conventions](https://developer.hashicorp.com/terraform/language/modules/develop/structure):

- Repository name is **`terraform-<PROVIDER>-<NAME>`**, so `terraform-google-n8n`.
- Resource names use **`snake_case`**. The "main" resource of a kind in this
  module is named `n8n` (e.g. `google_container_cluster.n8n`,
  `google_sql_database_instance.n8n`, `google_redis_instance.n8n`); this matches
  the registry convention of using a short, descriptive label rather than
  repeating the resource type.
- Variables and outputs use **`snake_case`** with a leading noun
  (`friendly_name_prefix`, `n8n_fqdn`, `gcp_region`, `static_ip`).
- Every variable has a `description` and a `type`. Most have a `validation`
  block that fails fast with a useful error message; preserve this when
  adding new inputs.
- Every output has a `description`. Outputs containing secrets are marked
  `sensitive = true`.
- Taggable Google Cloud resources receive `local.gcp_labels` where labels are
  supported.

### 4. Clear documentation

- `README.md` is the entry point. The `## Reference` section between
  `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is **auto-generated**;
  do not hand-edit it. All rendering options (formatter, output template,
  `lockfile: false` to keep providers shown as constraints) live in
  `.terraform-docs.yml`, so refreshing the README is one command:

  ```bash
  brew install terraform-docs   # or: see the install step in .github/workflows/terraform-tests.yml
  terraform-docs .
  ```

  CI installs the same version (`v0.24.0`, tracking the brew default) and
  runs `terraform-docs --output-check .`, see the `docs` job in
  `.github/workflows/terraform-tests.yml`. If your local version differs
  from CI's, the markdown table whitespace will drift and the check will
  fail; bump both together when upgrading.
  **Inside `modules/` itself** (the default `recursive-path` in
  `.terraform-docs.yml`), plain `terraform-docs .` and `terraform-docs
  --output-check .` silently no-op into printing help instead of erroring;
  pass the root config explicitly, e.g. `terraform-docs --config
  ../../.terraform-docs.yml .` from `modules/controllers`, or
  `../../../../.terraform-docs.yml` from a nested `modules/*/examples/*`
  directory.

- **`markdownlint`** (CI job, `markdownlint-cli2`) lints `README.md`,
  `AGENTS.md`, `CHANGELOG.md`, and `docs/*.md`. `.markdownlint.json` disables MD013
  (line-length; this repo's prose is not hard-wrapped), MD036
  (emphasis-as-heading; `docs/troubleshooting.md`'s deliberate
  Symptom/Cause/Fix convention), MD040 (fenced-code-language; a handful of
  pre-existing shell-prompt-style fences), and MD060 (table-column-style; a
  rule new enough that none of this repo's existing tables were written
  against it). README.md's generated `<!-- BEGIN_TF_DOCS -->` block is
  wrapped in `<!-- markdownlint-disable -->`/`<!-- markdownlint-restore -->`
  comments placed outside the block, so its anchor tags and placeholder
  tokens don't need hand-editing to pass MD033. Run locally with
  `markdownlint-cli2 "README.md" "AGENTS.md" "CHANGELOG.md" "docs/*.md"`.

- Each example has its own `README.md` documenting the runnable example.
- `docs/post-deployment.md` and `docs/destroy-cleanup.md` cover operator-facing
  concerns that don't belong inline in `README.md`.
- Inline comments in `.tf` files use the `# ── Section ──` banner style. Match
  it when adding new sections.

### 5. Standard module files

All of the following are present and should stay present:

- `README.md`, `LICENSE`, `versions.tf`, `variables.tf`, `outputs.tf`
- `examples/` with at least one runnable example
- `tests/` with at least one `.tftest.hcl` suite
- `.github/workflows/` with the CI pipeline above

## How to work in this repo (agent quick reference)

### Local development loop

```bash
# The veksh/godaddy-dns provider requires credentials even in plan-time tests.
# Export stubs once per shell session before running the godaddy example test
# (the other examples and the root suite need no credentials).
export GODADDY_API_KEY=stub GODADDY_API_SECRET=stub

terraform fmt -recursive                       # before committing
terraform init -backend=false                  # at module root
terraform validate
terraform test -verbose                        # plan-time, no GCP creds needed
# Faster iteration on one suite (CI runs the root this way, one file per job):
#   terraform test -filter=tests/defaults.tftest.hcl
tflint --init && tflint --format compact
terraform-docs --output-check .                # README drift check

# Chart-rendering regression check: pinned Helm CLI, no credentials, no
# Terraform. Mirrors the `chart-render` CI job.
tests/scripts/check-n8n-chart.sh

# Security baseline: pinned Checkov, both passes (default tfvars and the
# opt-in fixture that unblinds count-0 resources like the Redis exporter),
# same as the `checkov` + `checkov-opt-in` CI jobs. soft_fail is false, so
# an unapproved new finding exits nonzero.
tests/scripts/check-checkov.sh

# Markdown lint, same command as the `markdownlint` CI job.
markdownlint-cli2 "README.md" "AGENTS.md" "CHANGELOG.md" "docs/*.md"

# Local-only structure checks (not CI-gated).
scripts/check-variable-banners.sh
scripts/check-example-parity.sh

# Optional: with `task` installed, `task ci` runs everything above except
# checkov and version-drift (`task checkov`, `task version-drift`), plus the
# per-target loop below. See Taskfile.yml.

# Version-currency reports (never auto-bump; see docs/versioning.md).
# check-version-drift.sh compares the provider and chart pins against their
# upstream sources (not the CI toolchain pins; check those by hand).
# check-helm-chart-coverage.sh fails only if docs/helm-chart-coverage.md
# drifts from the pinned chart's actual values.yaml. chart-values-diff.sh
# is manual, run with a candidate version when picking up a chart bump:
#   tests/scripts/chart-values-diff.sh 1.12.0
tests/scripts/check-version-drift.sh
tests/scripts/check-helm-chart-coverage.sh

# Repeat the same five commands under every example and both controller
# targets. This exact target list mirrors the `validate`/`test`/`tflint`/`docs`
# job matrices in .github/workflows/terraform-tests.yml; keep both in sync
# when adding a target. Each line runs in its own subshell (the parens), so
# every `cd` is root-relative and unaffected by the previous line, unlike a
# bare `cd examples/x && ...` chain, which would leave the shell inside
# examples/x and break the next line's relative path.
# modules/controllers and its nested example are not the terraform-docs
# recursive-path default for a bare `terraform-docs .`, so they pass the root
# config explicitly with --config (see "Clear documentation" above).
(cd examples/small                       && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/medium                      && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/large                       && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/cloudflare                  && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/godaddy                     && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/split-ingress               && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/customer-managed-cluster    && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/customer-managed-redis      && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/customer-managed-gcs        && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/customer-managed-everything && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd examples/worker-pools                && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --output-check .)
(cd modules/controllers                  && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --config ../../.terraform-docs.yml --output-check .)
(cd modules/controllers/examples/direct-use && terraform init -backend=false && terraform validate && terraform test -verbose && tflint --init && tflint --format compact && terraform-docs --config ../../../../.terraform-docs.yml --output-check .)
```

A real deployment uses `terraform apply` from `examples/small/` with a
populated `terraform.tfvars`, but **never apply from CI** in this repo.

### When adding a new input

1. Add it to `variables.tf` (or `variables_gcp.tf`) with `description`, `type`,
   sensible `default` (if any), and a `validation` block when it adds meaningful
   guardrails. Align with existing patterns and avoid redundant checks.
2. Surface it on the resource(s) that consume it.
3. Add an `assert` in `tests/defaults.tftest.hcl` (and the relevant example
   test file if the variable is exercised by an example). See *Known mock
   provider limitations* above for guidance when end-to-end wiring cannot be
   tested under mocks.
4. Update `CHANGELOG.md`, add a bullet under `## [Unreleased] / ### Added`.
5. Re-run `terraform-docs .` to refresh the `README.md` reference table.
   **This step is CI-gated**; the `docs` job runs `terraform-docs
   --output-check .` and will fail the PR if the README is stale.
6. Run the full local loop (`terraform fmt -recursive`, `terraform validate`,
   `terraform test`) and confirm all tests pass **before committing**.

### When adding a new resource

1. Put it in the existing `.tf` file matching its concern (e.g. anything
   database goes in `cloudsql.tf`). Create a new file only for a genuinely new
   concern.
2. Apply `labels = local.gcp_labels` (or merge into it) if the resource
   supports labels.
3. Reference it from the relevant output, if it's user-facing.
4. Add a plan-time assertion if the resource encodes a non-obvious default.
5. Run `tflint` and `checkov` locally before pushing; CI will run them anyway,
   but failing fast saves a round trip.

### What *not* to do

- Don't configure providers inside the module. `versions.tf` declares
  `required_providers`; provider configuration is the caller's job (see
  `examples/small/providers.tf`).
- Don't introduce nested `module` calls without a strong reason; this module
  is intentionally flat so registry consumers can read it top to bottom.
- Don't commit `terraform.tfstate*`, `*.tfplan`, `apply*.log`, or
  `terraform.tfvars`. The `.gitignore` already covers these; check before
  committing if you ran `apply` locally inside an example.
- Don't hand-edit the `<!-- BEGIN_TF_DOCS -->` block in `README.md`.
- Don't widen `soft_fail` or silence lint rules without a comment explaining
  why and a follow-up TODO.
- Don't add inline lint-suppression comments (`<!-- markdownlint-disable -->`,
  `# tflint-ignore`, `# checkov:skip`) as a first response to a lint
  warning. Prefer fixing the root cause or updating the relevant config file
  (`.markdownlint.json`, `.tflint.hcl`). Inline suppressions are acceptable
  only for genuine false positives that cannot be resolved at the config
  level, and must include a comment explaining why.

## References

- [Terraform module structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Publishing modules to the Terraform Registry](https://developer.hashicorp.com/terraform/registry/modules/publish)
- [Terraform partnerships guidelines](https://developer.hashicorp.com/terraform/docs/partnerships)
- [Announcing the new Partner Premier Tier for the Terraform Registry](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
- [`terraform test` framework](https://developer.hashicorp.com/terraform/language/tests)
- [`terraform-docs`](https://terraform-docs.io/)
- [TFLint](https://github.com/terraform-linters/tflint) and [Checkov](https://www.checkov.io/)
