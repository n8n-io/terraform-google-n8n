## Why

`2026-09-21-add-google-parity-through-aws-0-5-0` deliberately omitted AWS's
`n8n_worker_pools`/`n8n_worker_extra_env` feature (EARLY ALPHA upstream,
tracked in that change's proposal.md, "Omit"). The user has now asked for it
ported anyway, as close to terraform-aws-n8n's own implementation as
possible, minimizing Google-specific divergence except where GKE's
capacity/KEDA wiring genuinely requires it. This proposal reverses that
exclusion.

## What changes

- Port `worker-pools.tf` from terraform-aws-n8n near-verbatim: the
  `n8n_worker_pools_min_n8n_minor`/`n8n_chart_renders_worker_pools` guard
  locals, the `n8n_worker_groups` mapping onto the chart's
  `queueMode.workerGroups`, the `n8n_worker_pools_chart_error` message, and
  `check.worker_pools_require_n8n_2_39` (all cloud-agnostic Helm/chart-
  versioning logic).
- Add `n8n_worker_pools`, `n8n_worker_extra_env`, and
  `n8n_worker_pools_chart_verified` variables with AWS's validation blocks
  ported near-verbatim (pool name grammar/length, no `default`, no
  duplicates, replica/concurrency bounds, reserved-name guards on
  `extra_env`), reusing this module's own CPU/memory quantity grammar
  (`capacity.tf`'s parser only accepts `m`-suffixed/bare CPU and
  `Ki`/`Mi`/`Gi`/bare memory, narrower than AWS's).
- Wire `queueMode.workerExtraEnv`/`workerGroups` and the
  `N8N_WORKER_POOLS_ENABLED` `extraEnv` entry into `n8n.tf`, and add the
  `lifecycle.precondition` on `helm_release.n8n` AWS uses to hard-fail a
  numbered, unverified chart pin.
- Fold each pool's own replica ceiling and resolved CPU/memory requests into
  `capacity.tf`'s existing node-capacity guardrail (Google's own CPU+memory
  model, not AWS's CPU-only `scaling.tf` derivation).
- Add `local.n8n_worker_pool_keda_metadata`: a Google-specific adaptation.
  AWS's pools use plain KEDA trigger metadata (`enableTLS`/
  `passwordFromEnv`/`username`) with no `TriggerAuthentication`, because
  ElastiCache needs no custom CA trust. Google's default worker uses a
  `TriggerAuthentication` for Memorystore's private CA
  (`redis_transit_encryption_enabled = true`), which the unreleased chart's
  `queueMode.workerGroups[].keda` schema is not confirmed to support for
  pools. Ported the plain-metadata form (matching AWS 1:1) and documented
  the CA-trust gap rather than guessing at an unverified schema extension.
- New `examples/worker-pools/`, mirroring AWS's own example: the same
  3-pool topology (`heavy`/`secteam`/`itop`), adapted to this module's GKE
  node-capacity variable (`gke_node_max_per_zone`, raised 4 → 6) instead of
  AWS's EKS `node_max`.
- Port `tests/scripts/verify-worker-pools.sh` near-verbatim (pure
  kubectl/Helm/KEDA logic); only the namespace output name differs
  (`n8n_kube_namespace`, not AWS's `namespace`).
- `terraform test` coverage at the root (variable contract + the chart-
  pairing precondition, which a mocked `plan` genuinely exercises) and in
  the new example (declared topology, `worker_pool_names` output).

## Capabilities

### Modified capabilities

- `kubernetes-ownership`: adds the worker-pools variables, chart-pairing
  precondition, and `worker-pools.tf` wiring.
- `redis-observability`: adds `local.n8n_worker_pool_keda_metadata`
  alongside the existing default-worker KEDA trigger wiring.
- `infrastructure-ownership`: `capacity.tf`'s guardrail now accounts for pool
  replica ceilings.

## Impact

Implementation touches `variables.tf`, a new `worker-pools.tf`, `n8n.tf`,
`capacity.tf`, `locals.tf`, `tests/defaults.tftest.hcl`, a new
`examples/worker-pools/` (registered in every CI matrix in
`.github/workflows/terraform-tests.yml`), a new
`tests/scripts/verify-worker-pools.sh`, `tests/scripts/README.md`,
`AGENTS.md`, and `CHANGELOG.md`. No new cloud resource type; the feature is
entirely Helm-values and Terraform-variable surface. Marked EARLY ALPHA in
every user-facing description, matching AWS's own upstream caveat: no
released n8n Helm chart renders `queueMode.workerGroups` yet, so this cannot
be verified end-to-end without a private/preview chart build.
