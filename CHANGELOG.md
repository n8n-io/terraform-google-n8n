# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md, Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

## [0.1.0] - 2026-09-29

Initial release. Nothing was tagged before this version. The pre-release
development history, including every intermediate rename and breaking change
made on `main`, is preserved in the
[pre-release `CHANGELOG.md`](https://github.com/n8n-io/terraform-google-n8n/blob/2a364954f8323942fa67874a3a1e67f4e6f2d90d/CHANGELOG.md).

### Added

- Production-grade, multi-main n8n Enterprise deployment in queue mode on
  Google Kubernetes Engine (GKE): dedicated main, worker, and webhook-processor
  pods, fronted by a native GKE Ingress (Google Cloud L7 load balancer).
  Requires an n8n Enterprise license for multi-main.
- **Explicit, per-layer ownership model.** Network/PSA, GKE, Cloud SQL,
  Memorystore Redis, the GCS bucket, the Kubernetes namespace, and ingress
  each have a `create_*` switch, and every autoscaler (HPA/KEDA) has its own
  `*_enabled` switch, so the module can own a layer end-to-end or attach to a
  caller-managed equivalent independently per layer. See
  [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md)
  for the full ownership/security-boundary matrix.
- 11 runnable example roots: `small`, `medium`, `large` (sizing tiers),
  `cloudflare` and `godaddy` (DNS-provider variants), `split-ingress`
  (public/private route isolation), `customer-managed-cluster`,
  `customer-managed-redis`, `customer-managed-gcs`, and
  `customer-managed-everything` (ownership-boundary variants), and
  `worker-pools` (**EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE**, tracks
  an unreleased upstream n8n/chart preview feature).
- Regional, VPC-native GKE cluster with a managed, autoscaled node pool, a
  dedicated least-privilege node service account, GKE Dataplane V2, Shielded
  nodes, and Workload Identity so pods authenticate to Google Cloud APIs
  without static keys. `create_gke = false` attaches to an existing cluster
  instead.
- Public `modules/controllers` submodule: the KEDA Helm release and an
  optional pd-balanced `StorageClass` behind a typed, validated contract,
  independently consumable (see `modules/controllers/examples/direct-use`).
- Cloud SQL for PostgreSQL over Private Service Access, with restore/clone
  support, configurable backup and transaction-log retention, optional query
  logging, and an explicit Cloud KMS create-or-reference CMEK key. External
  PostgreSQL is supported via `create_postgres_instance = false`.
- Memorystore for Redis over Private Service Access, with optional AUTH, TLS
  in transit (trusted end-to-end by n8n and KEDA), opt-in RDB persistence, an
  opt-in private Redis-metrics exporter, and its own CMEK key. External
  Redis-compatible services are supported via `create_redis_instance = false`.
- Google Cloud Storage bucket for n8n binary data, reached through the
  S3-compatible driver via an HMAC key, with CMEK, public-access prevention, a
  noncurrent-version lifecycle rule, and a dedicated access-log bucket. A
  bring-your-own bucket is supported via `create_gcs_bucket = false`; HMAC
  identity ownership is a separate, independent switch and works with either
  a module-managed or a bring-your-own bucket.
- KEDA-based worker autoscaling on Redis/Bull queue depth, including
  per-pool scaling for the EARLY ALPHA `n8n_worker_pools` feature, plus an
  HPA for main and webhook-processor pods. `n8n_worker_keda_pause` and
  `n8n_worker_keda_paused_replica_count` pause autoscaling of the default
  worker Deployment only; worker pools keep scaling.
- Google Secret Manager access for n8n's own External Secrets feature, scoped
  to a caller-declared secret allow-list.
- TLS via `tls_mode`: `google_managed` (default, `ManagedCertificate`),
  `secret` (existing Kubernetes TLS secret, e.g. cert-manager), `custom`
  (bring-your-own PEM), and `self_signed`; optional Cloud DNS A-record
  management or bring-your-own DNS; multi-hostname coverage via
  `n8n_additional_domains`; an optional module-managed Cloud Armor security
  policy (including the Log4Shell/CVE-2021-44228 canary rule) or an existing
  policy reference; and an optional ingress SSL policy.
- A wide n8n runtime-configuration surface: custom n8n/task-runner images and
  pull secrets, extra volumes/env, a credentials-overwrite Secret reference, a
  custom task-runner launcher-config ConfigMap reference, community-package
  registry/security controls, pod-level DNS config, graceful-shutdown timeout,
  execution-data storage mode (`database` or `s3`), and license delivery via a
  direct key or an existing Secret reference.
- A non-blocking managed-GKE capacity guardrail (`capacity.tf`/`checks.tf`)
  that warns, at plan time, when configured replica maxima across main,
  worker, and webhook-processor pods could exceed the node pool's estimated
  allocatable CPU/memory.
- A curated Checkov security baseline: CMEK key rotation, Cloud SQL audit
  logging flags, VPC Flow Logs plus an explicit deny-all-ingress firewall
  rule, and GKE Dataplane V2/Shielded-node/no-client-certificate
  hardening, with CI running Checkov `soft_fail: false` (hard gate) plus a
  second opt-in pass (`tests/checkov/opt-in.tfvars`) that enables the
  default-off Redis exporter, which a default-tfvars scan cannot evaluate.
  The opt-in pass runs with `--skip-path examples` and accepts only exact
  root-module addresses as proof that it evaluated the exporter Deployment
  and Service. Against Checkov `3.3.20`, the default pass reports 111
  passed, 0 failed, and 189 skipped checks, and the opt-in pass reports 0
  failed checks.
- Plan-time `terraform test` suites at the module root, in every example, and
  in `modules/controllers`, using mocked providers so they run offline with no
  Google Cloud credentials, plus a credential-free n8n Helm chart rendering
  regression check (`tests/scripts/check-n8n-chart.sh`).
- A post-apply smoke test (`tests/scripts/smoke-test.sh`) for live
  deployments. It checks the queue-mode topology the module always deploys,
  fails when the `n8n-worker` Deployment is absent, and asserts the
  single-main safeguards when one main replica is selected: a main HPA
  pinned to one replica (or one fixed replica when
  `n8n_main_hpa_enabled = false`), the `Recreate` strategy, and PDB
  `minAvailable = 0`.
- Contributor tooling: `CONTRIBUTORS`, a `.github/CODEOWNERS` header, a
  `Taskfile.yml` that wraps the local check loop (`task ci`) across the
  module root, every example, and `modules/controllers`, and
  `scripts/check-variable-banners.sh` (`task banners`), which verifies every
  `variable` and `output` block sits under its documented `# ── Section ──`
  banner.
- Governance and operations docs: `docs/versioning.md` (every pinned version,
  its bump tier, and a weekly automated drift report), `docs/upgrading-n8n.md`,
  `docs/manual-verification-checklist.md`, `docs/customer-managed-infrastructure.md`,
  `docs/troubleshooting.md`, `docs/destroy-cleanup.md`, `docs/post-deployment.md`,
  `docs/istio-ingress.md`, `docs/helm-chart-coverage.md`, and `ROADMAP.md`.

### Compatibility

- **Terraform CLI:** `>= 1.9`. CI runs the pinned version listed in
  [`docs/versioning.md`](./docs/versioning.md).
- **`google` and `google-beta` providers:** `~> 6.0`.
- **`kubernetes` provider:** `~> 3.0`.
- **`helm` provider:** `~> 3.0`.
- **`kubectl` provider (`gavinbunney/kubectl`):** `~> 1.14`.
- **`tls` provider:** `~> 4.0`. **`random` provider:** `~> 3.0`. **`time`
  provider:** `~> 0.14`.
- **n8n Helm chart:** `1.13.0` default (n8n `2.40.5`). **KEDA Helm chart:**
  `2.20.1` default. See [`docs/versioning.md`](./docs/versioning.md) for the
  complete pin inventory.
- **Validated on:** a recent GKE `REGULAR` release channel version and Cloud
  SQL `POSTGRES_16`.
- **CI toolchain:** Checkov `3.3.20` (`bridgecrewio/checkov-action@v12.3126.0`)
  and TFLint `v0.64.0`.

### Known limitations

- This module is preliminary and not scale-validated (no load test). Expect
  breaking changes in `0.x` minor releases, as described in
  [README.md, Stability & versioning](./README.md#stability--versioning).
- `kubernetes_namespace` and several `kubernetes_secret` resources still use
  the unversioned resource types, so they plan with a cosmetic "Deprecated
  Resource" warning under `kubernetes` provider 3.x. They are not renamed to
  their `_v1` equivalents because the provider has no `moved` support across
  that rename (`hashicorp/terraform-provider-kubernetes` issue #2812), and a
  rename would destroy and recreate the namespace. If your root module
  constrains `kubernetes` to `~> 2.0`, widen it first, or `terraform init`
  cannot satisfy both constraints.
- See [README.md → Out of scope](./README.md#out-of-scope) for what this
  release explicitly does not cover.
- `n8n_worker_pools` is **EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE**: it
  tracks an n8n feature and a chart preview build that are themselves
  unreleased upstream (see the `worker-pools` example's README).
- [`docs/manual-verification-checklist.md`](./docs/manual-verification-checklist.md)
  lists 15 runtime-only scenarios (topology transitions, credential/config
  rotation restarts, restore/clone key continuity, TLS/DNS alias coverage,
  the Redis command-prefix transition, Memorystore RDB recovery, and license
  entitlement boundaries) that mocked `terraform test` cannot exercise.
  Several were run live against disposable `examples/small` deployments
  (recorded in that document); the rest are tracked there as not yet run.

[Unreleased]: https://github.com/n8n-io/terraform-google-n8n/compare/0.1.0...HEAD
[0.1.0]: https://github.com/n8n-io/terraform-google-n8n/releases/tag/0.1.0
