## Tasks

- [x] Read AWS `worker-pools.tf`, `variables.tf` (worker-pools sections),
      `n8n.tf` (queueMode/extraEnv/precondition wiring), `locals.tf`
      (`keda_redis_auth_metadata`), `scaling.tf` (pool capacity counting),
      `examples/worker-pools/*`, `tests/scripts/verify-worker-pools.sh` at
      tag `0.5.0`.
- [x] Add `n8n_worker_extra_env`, `n8n_worker_pools`,
      `n8n_worker_pools_chart_verified` to `variables.tf`, ported near-
      verbatim from AWS with this module's own CPU/memory quantity grammar.
- [x] Create `worker-pools.tf`: `n8n_chart_renders_worker_pools`,
      `n8n_worker_groups`, `n8n_worker_pools_chart_error`,
      `check.worker_pools_require_n8n_2_39`, and the Google-specific
      `local.n8n_worker_pool_keda_metadata` (documented CA-trust gap versus
      the default worker's `TriggerAuthentication`).
- [x] Wire `queueMode.workerExtraEnv`/`workerGroups`,
      `N8N_WORKER_POOLS_ENABLED` `extraEnv`, and the
      `lifecycle.precondition` on `helm_release.n8n` into `n8n.tf`.
- [x] Add `N8N_WORKER_POOLS_ENABLED`/`N8N_WORKER_POOL_NAME` to
      `locals.tf`'s `n8n_managed_env_names`.
- [x] Fold pool replica ceilings and resolved CPU/memory requests into
      `capacity.tf`'s `capacity_requested_max_cpu_millicores`/
      `capacity_requested_max_memory_mib`.
- [x] Add `terraform test` coverage in `tests/defaults.tftest.hcl`: default-
      empty contract, valid-pool plan, chart-pairing precondition (pass and
      fail), name/duplicate/bounds/reserved-name rejections, scale-to-zero
      acceptance, and the image-tag `check` warning.
- [x] Create `examples/worker-pools/` (variables.tf, main.tf, outputs.tf,
      providers.tf, versions.tf, `.terraform-docs.yml`,
      `terraform.tfvars.example`, README.md, `tests/defaults.tftest.hcl`):
      the same `heavy`/`secteam`/`itop` topology as AWS's example, adapted
      to `gke_node_max_per_zone`.
- [x] Register `examples/worker-pools` in every CI matrix (`docs`,
      `validate`, `test`, `tflint`) in
      `.github/workflows/terraform-tests.yml`, and in `AGENTS.md`'s file-
      layout table and local dev-loop command list.
- [x] Port `tests/scripts/verify-worker-pools.sh` (namespace output renamed
      to `n8n_kube_namespace`) and document it in `tests/scripts/README.md`.
- [x] Add a `CHANGELOG.md` entry under `[Unreleased] / Added`.
- [x] Run `terraform fmt -recursive`, `terraform validate`,
      `terraform test` (root: 498 passed; `examples/worker-pools`: 3
      passed), `tflint` (root and the new example, both clean),
      `terraform-docs --output-check` (root and the new example, both
      clean), `tests/scripts/check-checkov.sh` (both passes clean), and
      `markdownlint-cli2` on the CI-scoped targets (clean).
- [x] Review pass (reviewer subagent + Terraform 1.9.8 rerun). Fixed: the
      ported `verify-worker-pools.sh` compared pool AUTH metadata against a
      default worker that carries AUTH through a `TriggerAuthentication`
      (would fail on a healthy default deployment); pool `enableTLS` now
      follows the default worker's exact rendering rule and the script
      compares TLS only, checking `passwordFromEnv` against the pool's own
      pod template. Added `check.worker_pools_with_managed_redis_tls_ca`
      (+2 tests; both later superseded in PR review by wiring
      `keda.authenticationRef` to the shared `TriggerAuthentication`, once
      the published preview chart was verified to support it), named pools in both `capacity.tf` check messages, fixed
      two comment attributions, added `examples/worker-pools` to
      `scripts/check-example-parity.sh` (and the three `small` passthroughs
      it flagged as missing). Root `defaults.tftest.hcl`: 104 passed under
      Terraform 1.9.8; full root suite 498 passed under 1.9.8 before the
      two added runs; example: 3 passed under 1.9.8.
