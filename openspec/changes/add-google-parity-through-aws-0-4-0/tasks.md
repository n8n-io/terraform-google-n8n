# Implementation checklist

Each numbered section is one focused implementation iteration, in dependency order. Read `AGENTS.md` and the committed Terraform style/test skills before implementation. Use the contracts in `design.md` and `specs/`, not AWS resource names. For each new input, include its changelog entry and regenerate the affected Terraform reference tables. Run that section's plan/render tests on Terraform 1.9.8 before marking it complete.

Only automated checks and delivery of the manual checklist gate completion. Do not apply live infrastructure, publish a release, or mark manual runtime checks passed as part of this checklist.

## 1. Establish credential-free chart regression checks

- [x] 1.1 Record the baseline root/example checks and current security findings in a verification report; verify the report names the Google commit, AWS tag, chart version/digest, tool versions, and every CI target.
- [x] 1.2 Extract only the current input-derived chart fragments needed by this change into shared locals in `locals.tf`/`n8n.tf`; verify baseline mock tests and rendered values preserve existing defaults without new public outputs or submodules.
- [x] 1.3 Add `tests/scripts/check-n8n-chart.sh` using isolated state and synthetic references; verify it renders the pinned chart without credentials, checks current floor seeding and both Service BackendConfig annotations, and fails on an intentionally wrong expected value.

## 2. Validate scaling and resource inputs

- [x] 2.1 Add non-null whole-number bounds and ordering validation for application replicas, worker concurrency, scaler thresholds, GKE per-zone bounds, and existing boot-disk size; verify valid defaults and negative/fractional/reversed cases in plan tests.
- [x] 2.2 Validate CPU/memory inputs against the documented capacity-parser grammar without adding a new parser abstraction; verify representative valid quantities and invalid quantities fail through variable validation on Terraform 1.9.8 rather than expression errors.
- [x] 2.3 Add `n8n_webhook_hpa_scale_up_stabilization_window_seconds` to the standalone HPA in `scaling.tf`; verify default zero, explicit 60, invalid bounds, and disabled-HPA omission.

## 3. Implement topology-aware main behavior

- [x] 3.1 Derive single-main/multi-main from the selected HPA minimum or fixed count and wire the effective HPA ceiling, main strategy, and PDB; verify renders for counts 1, 2, and 3 on both scaler ownership paths, including a high unused single-main maximum.
- [x] 3.2 Update `capacity.tf` to consume the effective main ceiling; verify a single-main test counts one main/runner while multi-main and external-GKE cases retain their contracts.
- [x] 3.3 Add regression cases for returning to multi-main and unchanged worker/webhook strategies; verify the chart renders main-only Recreate/PDB behavior and no disabled scalers.

## 4. Add database health and acquisition tuning

- [x] 4.1 Add the four `db_ping_*`/`db_postgresdb_connection_timeout_ms` inputs and shared runtime wiring; verify null omission and explicit values on all three n8n roles for managed and external PostgreSQL.
- [x] 4.2 Add positive-integer, zero-acquisition-timeout, overflow, and extra-env collision tests; verify each fails or passes at the documented boundary on Terraform 1.9.8.
- [x] 4.3 Correct the pool-size description to a lazy per-process maximum and explain its interaction with health-check acquisition; verify documentation no longer claims every pod continuously holds the configured number of connections.

## 5. Add queue lock and stall controls

- [x] 5.1 Add the three nullable `n8n_queue_worker_*` settings through one nested `redis.worker` map; verify a combined render retains duration, renewal, and stalled interval together without duplicate queue environment entries.
- [x] 5.2 Add effective-default cross-validation and chart-boundary tests; verify short duration with omitted renewal, equal renewal/duration, fractions, and stalled interval zero fail while supported values pass.

## 6. Add execution-save controls

- [x] 6.1 Replace the four hardcoded `executions.data` values with dedicated inputs preserving all/all/false/true defaults; verify default and mixed-policy renders on main, worker, and webhook containers.
- [x] 6.2 Reserve all four `EXECUTIONS_DATA_SAVE_*` names and add migration guidance; verify collisions fail and each rendered container contains exactly one entry per save setting.

## 7. Complete Redis namespace isolation

- [x] 7.1 Wire and reserve `N8N_REDIS_KEY_PREFIX` and share the effective waiting/active key list in `locals.tf` and KEDA values; verify custom prefixes change command, Bull, and scaler coordinates together.
- [x] 7.2 Add default-prefix and two-deployment isolation cases plus a queue-drain upgrade note; verify null omits both overrides and different prefixes on one endpoint produce distinct command/queue names.

## 8. Add direct encryption-key recovery

- [x] 8.1 Add sensitive `n8n_encryption_key`, generation gating, core Secret wiring, and effective sensitive output; verify generated, valid-direct, external-core, malformed, and conflicting-source plan cases.
- [x] 8.2 Update restore/clone continuity diagnostics and tests in the PostgreSQL ownership suite; verify direct or external-core continuity suppresses only the missing-key warning and does not bypass restore-source validation.

## 9. Remove inline license delivery

- [x] 9.1 Add a dedicated managed Secret for direct licenses and use effective license Secret coordinates in Helm values; verify external references create no managed license Secret and all roles render `secretKeyRef` without a literal key.
- [x] 9.2 Preserve namespace ordering, source exclusivity, and the external-core separate-license contract; verify existing Kubernetes ownership tests and synthetic-license rendering cases pass.

## 10. Add caller-managed volume contracts

- [x] 10.1 Add typed `n8n_extra_volumes` and `n8n_extra_volume_mounts`, including item mappings and octal permission conversion; verify single-source, name/path uniqueness, mount-reference, canonical-path, protected-path, and `0440` conversion tests.
- [x] 10.2 Merge caller mounts with managed Redis CA mounts on every n8n role; verify the combined TLS-plus-ConfigMap/Secret/PVC rendering matrix does not create or read caller objects.
- [x] 10.3 Extend custom-extension diagnostics to recognize a covering mount; verify stock-image plus covering mount succeeds without the current missing-image warning, while an uncovered path still warns.

## 11. Add credential-overwrite Secret references

- [x] 11.1 Add validated `n8n_credentials_overwrite_secret_ref` and read-only single-key mounts; verify all n8n roles receive the selected file path and no overwrite payload or Secret data lookup appears in the module.
- [x] 11.2 Add conditional environment/volume/path collision guards and null-path regression cases; verify enabled collisions fail while the disabled escape hatch remains accepted.
- [x] 11.3 Document missing-key failures and manual rotation restarts; verify the runbook names all three deployments and makes no automatic Secret-hash rollout claim.

## 12. Add task-runner configuration controls

- [x] 12.1 Add `n8n_task_runner_custom_config` with separate ConfigMap-name/key validation and enabled-runner requirement; verify main/worker sidecar mounts, custom keys, null omission, and disabled-runner rejection against chart 1.10.1.
- [x] 12.2 Add `n8n_task_runner_timeout=300` separately from the existing request timeout; verify distinct explicit execution/acceptance values, integer validation, and protected `N8N_RUNNERS_*` ownership.
- [x] 12.3 Document whole-file launcher replacement, image-version alignment, and main/worker restarts; verify the examples do not create permissive allow-lists or read caller ConfigMap contents.

## 13. Add pod DNS configuration

- [x] 13.1 Add nullable typed `n8n_dns_config` and emit only supplied members; verify all three pod roles render the same custom resolver/search/options configuration while defaults omit it.
- [x] 13.2 Add nameserver, search-list, option-uniqueness, and `ndots` boundary tests compatible with supported GKE releases; verify fourth nameserver, malformed IP, excessive searches, duplicate options, and `ndots=16` fail without a Terraform 1.9 null error.

## 14. Add the V8 heap ceiling

- [x] 14.1 Add `n8n_node_max_old_space_size_mb` and conditional `NODE_OPTIONS` protection; verify null and explicit settings across all n8n containers without changing runner containers.
- [x] 14.2 Add minimum/integer/collision tests and smallest-container memory guidance; verify legacy `NODE_OPTIONS` remains accepted at null and documented examples leave headroom beneath Google's webhook memory limit.

## 15. Add registry and security-related runtime settings

- [x] 15.1 Add `n8n_community_packages_registry` with credential-free HTTPS validation and a reserved environment name; verify all-role rendering, null omission, invalid URL rejection, and entitlement/authentication documentation.
- [x] 15.2 Add optional unverified-package and compression size/entry controls with dedicated reserved names; verify null follows upstream defaults, explicit false survives rendering, and invalid numeric values fail validation.

## 16. Add a private Redis exporter

- [x] 16.1 Add the opt-in image/switch inputs, hardened Deployment, ClusterIP Service, and nullable Service-name output in `observability.tf`/`outputs.tf`; verify default resource absence, one-replica Recreate behavior, independent metrics/KEDA toggles, and every pod security field through plan assertions.
- [x] 16.2 Reuse effective Redis endpoint, ACL, password Secret, exact queue keys, and managed Memorystore CA; verify managed TLS/AUTH, external Secret/ACL/TLS, unauthenticated plaintext, and custom-prefix cases without inline passwords or verification bypasses.
- [x] 16.3 Add explicit namespace/node dependencies and exporter requests to managed capacity estimates; verify ownership combinations and updated capacity totals, with no estimate for customer-managed GKE.

## 17. Add Cloud SQL operational controls

- [x] 17.1 Add optional backup count and transaction-log retention in `variables_gcp.tf`/`cloudsql.tf`; verify count/edition ranges, omitted defaults, enabled backup/PITR, and external-instance ignored-input tests.
- [x] 17.2 Add opt-in DDL/slow-query logging without changing default Query Insights or TLS behavior; verify exact PostgreSQL flags, disabled defaults, and external-instance warnings, and document query-text exposure.

## 18. Add opt-in Memorystore persistence

- [x] 18.1 Add the persistence switch, period enum, and start timestamp and wire managed RDB configuration; verify default-disabled, all supported periods, invalid timestamps, and external ownership cases.
- [x] 18.2 Add ignored-input diagnostics and recovery guidance; verify documentation distinguishes last-snapshot recovery from backup retention and describes stale data, replay, memory/latency overhead, and independent export/import backups.

## 19. Correct canonical application URLs

- [x] 19.1 Define one effective webhook URL, emit both webhook environment names, and set the editor URL from `n8n_fqdn`; verify default and distinct-host values on every n8n role.
- [x] 19.2 Validate webhook base URLs and reserve `N8N_WEBHOOK_URL`; verify malformed/credential/query/fragment cases fail and the migration note identifies the editor OAuth callback host.

## 20. Add aliases and guarded ingress annotations

- [x] 20.1 Add normalized `n8n_additional_domains`, effective host output, and non-conflicting `ingress_annotations`; verify hostname/collision validation and caller-owned-ingress ignored-annotation behavior.
- [x] 20.2 Apply the common host list to full ingress routes, alias Cloud DNS records, Google-managed certificates, self-signed SANs, and TLS host declarations; verify all TLS modes, the 100-domain limit, default canonical resource stability, and no-ingress resource absence.
- [x] 20.3 Add DNS-zone and caller-certificate prerequisites; verify tests preserve canonical URL outputs and documentation does not claim to inspect external Secret certificates.

## 21. Build the split-ingress example infrastructure

- [x] 21.1 Scaffold `examples/split-ingress` with standard files and local `.terraform-docs.yml`, using `create_ingress=false`; verify `terraform init -backend=false` and Terraform 1.9.8 validation without any live apply.
- [x] 21.2 Define example-owned public/global and private/regional addresses, proxy-only subnet, scoped proxy firewall, and exposure-specific Services/BackendConfigs; verify resource scopes and no takeover of Helm-owned Services through mocked tests and chart-selector assertions.
- [x] 21.3 Define caller TLS Secret and DNS/reachability prerequisites with explicit provider configuration; verify the example does not attach external-only certificate/FrontendConfig wiring to the internal ingress or install a VPN/certificate controller.

## 22. Complete split-ingress routing and verification

- [x] 22.1 Add public webhook-only and private editor-plus-webhook HTTPS ingress rules using module route/port outputs; verify public rules contain no main backend or catch-all and private rules cover all required families.
- [x] 22.2 Complete example outputs, README, synthetic input file, and plan tests for topology/ownership combinations; verify the README names internal/public DNS and certificate responsibilities and no credentials are committed.
- [x] 22.3 Add the example to every CI validation/test/lint/docs target and rendering selector checks; verify the local target inventory matches the workflow and documentation generation actually runs.

## 23. Curate the Google security baseline

- [ ] 23.1 Pin the selected Checkov version for local and CI use and refresh the baseline from section 1; verify a report groups every remaining finding by Google resource, actual risk, scanner limitation, or intentional ownership choice.
- [ ] 23.2 Fix in-scope real findings and add explicit tests for scanner coverage gaps; verify repeated scans contain no unexplained finding and no resource loses an existing curated protection, including Cloud Armor's CVE rule.
- [ ] 23.3 Record narrowly scoped justified exceptions where a fix conflicts with the supported ownership/feature contract; verify no broad check suppression or undocumented change to unrelated defaults is introduced, and escalate any newly discovered architectural change rather than assuming it.

## 24. Make CI and local gates agree

- [ ] 24.1 Wire the chart-rendering script and pinned tools into CI and documented local commands; verify a clean credential-free run on Terraform 1.9.8 and failure for a controlled wrong-value rendering fixture.
- [ ] 24.2 Replace blanket Checkov soft-fail after the curated scan passes; verify the same local/CI command returns nonzero for an unapproved security violation.
- [ ] 24.3 Correct root-relative verification loops in `AGENTS.md` and contributor guidance, including both controller targets; verify the target set equals CI and each Terraform documentation command uses the correct config.

## 25. Update application examples and sizing guidance

- [ ] 25.1 Expose the main floor in every application example and preserve each existing effective default; verify example mock tests allow single-main and retain current medium/large defaults without altering the controller-only example.
- [ ] 25.2 Pass through existing GKE boot-disk sizing and relevant pool/runtime tuning in the sizing examples rather than hardcoding AWS values; verify passthrough tests and unchanged Google resource sizing defaults.
- [ ] 25.3 Correct large-tier prose to match the actual worker ceiling and explain lazy pool budgets, DNS, heap, disk pressure, pruning, and RDB considerations; verify all numerical tables agree with example inputs and retain the not-scale-validated warning.

## 26. Deliver upgrade and manual verification guidance

- [ ] 26.1 Write `docs/upgrading-n8n.md` and update README/ownership/troubleshooting/destroy guidance; verify coverage of license/topology boundaries, new environment migrations, reference restarts, exact-key recovery, URL changes, Redis transitions, replica-floor resets, and any actual address changes.
- [ ] 26.2 Extend `tests/scripts/README.md` and the safe inspection portions of `smoke-test.sh` for the new contracts; verify shell syntax and ensure drains, restarts, recovery, and cloud applies are never run automatically by CI or the default inspection command.
- [ ] 26.3 Deliver the manual Google checklist with expected results and safety prerequisites for every runtime-only scenario; verify all unperformed checks are marked not run and include exporter CA/metrics, licensing, restore decryption, aliases, and private/public route isolation.
- [ ] 26.4 Finish the changelog and retain or link the applicability matrix from operator documentation; verify every port/adaptation maps to an implemented input/fix/test and every exclusion remains explicit.

## 27. Run final automated acceptance

- [ ] 27.1 Run `terraform fmt -check -recursive`, backend-free initialization, validation, mocked tests, TFLint, and Terraform documentation checks across the root, all examples, and both controller targets on Terraform 1.9.8; verify every target passes with only GoDaddy stub credentials where required.
- [ ] 27.2 Run the complete pinned-chart rendering matrix, blocking security command, shell checks, and `openspec validate add-google-parity-through-aws-0-4-0 --strict`; verify defaults, combined overrides, invalid inputs, and all ownership paths pass without a live cluster.
- [ ] 27.3 Review the diff and final evidence report against `parity-matrix.md` and all delta scenarios; verify no unrelated implementation, AWS-only flags, blanket exceptions, leaked secrets, unsupported version claim, or unperformed live-test success is included.
