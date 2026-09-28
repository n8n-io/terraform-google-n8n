## Why

AWS's terraform-aws-n8n cut release 0.5.0 on 2026-09-21. Most of it is version currency and CI hardening, but several items change caller-visible behavior or close real gaps the Google module has today: a breaking Kubernetes provider bump, a real DNS/pull-secret validation gap, and a checkov blind spot on count-0 (opt-in) resources. This proposal is cumulative through 0.5.0, building on the completed `add-google-parity-through-aws-0-4-0` change; it does not re-litigate anything already ported, adapted, or explicitly excluded there. AWS's early-alpha `n8n_worker_pools` feature is deliberately omitted from this round (see Exclude below).

## What changes

- Compare the complete AWS 0.5.0 diff against the Google baseline at HEAD. Record each item as a port, Google-specific adaptation, existing capability, or exclusion in `parity-matrix.md`.
- **BREAKING:** Bump the `kubernetes` provider floor to `~> 3.0` (from `~> 2.0`) across the root module, `modules/controllers`, and every example: mirrors AWS's identical bump and surfaces the same cosmetic deprecation warnings on this module's unversioned `kubernetes_namespace`/`kubernetes_secret` resources. Bump `time` to `~> 0.14` and the default `n8n_chart_version` to `1.11.0`.
- **Omit** `n8n_worker_pools`/`n8n_worker_extra_env` and `examples/worker-pools/` for this round: the upstream chart support ships only on an unnumbered preview branch, and the feature is not adopted until the chart and n8n both cut a numbered release carrying it. Revisit in a future parity round once that happens.
- Close a real DNS/Kubernetes-name validation gap: bound `n8n_fqdn`, `n8n_additional_domains`, and `n8n_image_pull_secrets` to the actual per-label 63-character DNS-1123 rule (today only total length is checked, and empty/hyphen-boundary labels slip through), and add a certificate common-name length precondition on the self-signed TLS path.
- Close a real checkov blind spot: the opt-in `redis_exporter` Deployment plans at count 0 by default and is silently dropped from every scan; add a second CI/local checkov pass against an opt-in-enabled fixture plus `terraform test` assertions pinning its security context, capabilities, memory limit, digest, and probes.
- Pin `redis_exporter_image` by digest as well as tag, matching the exact upstream image AWS pinned.
- Add `docs/versioning.md`, a version-drift report script, a helm-chart-coverage doc and checker, a chart-values-diff helper, an example-parity checker, and `docs/istio-ingress.md`, each adapted to this module's provider/chart/example set and to plain-script conventions (no `task`/Taskfile dependency, since this repo has neither).
- Add CI markdownlint coverage for `README.md`, `AGENTS.md`, and `docs/*.md`.
- Add "Production considerations" sections to every example README that lets the module own Cloud SQL or GCS, and pass the existing `postgres_backup_retained_backups`/`postgres_transaction_log_retention_days` inputs through every such example (today only `postgres_deletion_protection`/`gcs_force_destroy` are). Document why `cloudflare`/`godaddy` omit `n8n_additional_domains`.
- **Exclude**, with rationale: the RDS/Aurora PostgreSQL 18 minor bump (Google stays on `POSTGRES_16` by deliberate choice, unrelated to this release), the metrics-server chart bump (GKE has no metrics-server install to bump), and CI `TF_VERSION`/`TFLINT_VERSION` currency (tracked separately; this module's CI floor is deliberately pinned per `AGENTS.md`'s documented 1.9.x-strictness rationale, and bumping it is a version-currency decision, not a parity one).

## Capabilities

### Modified capabilities

- `kubernetes-ownership`: provider floor bump, DNS/name validation hardening, certificate CN bound.
- `redis-observability`: exporter image digest pin, checkov opt-in-resource coverage.
- `infrastructure-ownership`: backup-tuning passthrough parity across examples, "Production considerations" documentation.
- `operator-docs`: versioning inventory, drift/coverage/diff tooling, Istio routing doc.
- `release-verification`: markdownlint CI job, example-parity checker.

## Impact

Implementation touches `versions.tf`, `modules/controllers/versions.tf`, every `examples/*/providers.tf`, `variables.tf`/`variables_gcp.tf`, `observability.tf`, `dns.tf`, `locals.tf`, CI (`.github/workflows/terraform-tests.yml` plus a new markdownlint job), `docs/`, `tests/scripts/`, and `scripts/`. No new example, no new Terraform resource type, and no cloud resource types beyond what 0.4.0 parity already introduced. Keep the Google naming and ownership model, native GKE controllers, and current PostgreSQL major.


This proposal is the plan only. `design.md`, `tasks.md`, and capability spec deltas under `specs/` follow once this scope is confirmed. No implementation, live apply, or release is part of this proposal.
