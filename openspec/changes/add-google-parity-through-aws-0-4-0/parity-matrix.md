# AWS through 0.4.0 applicability review

## Baselines and evidence

- AWS tag: [`0.4.0`](https://github.com/n8n-io/terraform-aws-n8n/tree/0.4.0), commit `7e91a42f32df4cbcbcf8fc5229bb765c27202ff4`. The tag has no `v` prefix.
- Google baseline: `f686a1d7f1020d69b42f5cee116af5f93f4e6342`, including the completed full-stack modularity change.
- Review scope is cumulative through 0.4.0, not only the 0.3.0 to 0.4.0 diff. Later AWS changes are excluded.
- Primary AWS sources: [release notes][release], [complete changelog][changelog], [inputs][inputs], [n8n wiring][aws-n8n], [scaling][aws-scaling], [exporter][aws-exporter], and [chart check][aws-chart-test]. Release notes alone omit earlier gaps and some chart limitations.
- Google chart: OCI `ghcr.io/n8n-io/n8n-helm-chart/n8n:1.10.1`, pulled during this review with digest `sha256:9bc2201221166c95d6c6d404d8ef568a371038a860e628ee85e21d96c68277dd`. Inspected `values.yaml`, environment helpers, schema constraints, and template references. A credential-free single-main `helm template` succeeded. This does not verify a deployment or module implementation.

`Port` means missing cloud-independent behavior. `Adapt` means the goal applies but Google or this module requires a different contract. `Existing` means retain and regression-test, not reimplement. `Exclude` means no change in this plan; a rationale follows.

## Application and Kubernetes

| AWS feature or fix | Decision | Google evidence and planned action |
| --- | --- | --- |
| Single-main Business topology and safe maintenance, 0.4.0 | Adapt | `n8n.tf` always sets `multiMain.enabled=true`. Derive topology from the selected main floor, including Google's fixed-replica path; clamp the managed single-main HPA to 1; set main-only Recreate and PDB minimum 0. Keep queue workers, webhook processors, and feature-specific license requirements. |
| Main floor passthrough in every example, 0.4.0 | Port | Expose it in all application examples, preserving each example's existing effective floor. Do not change the controller-only example. |
| Database ping and acquisition tuning, 0.4.0 | Port | `DB_` is blocked by `n8n_extra_env`; only pool size and SSL have dedicated controls. Add four dedicated settings for managed and external PostgreSQL. |
| Bull lock, renewal, stall interval, 0.4.0 | Port | `QUEUE_` is reserved. Add three controls through chart `redis.worker`, with effective-default validation. Do not expose the removed runtime `QUEUE_WORKER_MAX_STALLED_COUNT` or promise stall interval 0 with chart 1.10.1. |
| Four execution-save controls and collision fix, 0.4.0 | Port | `n8n.tf` hardcodes all/all/false/true. Replace literals at this chart's **`executions.data`** path, not the `config.data` path mentioned in parts of the AWS changelog. Reserve all four environment names. |
| Task-runner launcher ConfigMap, 0.4.0 | Port | Add a name/key reference to `taskRunners.customConfig` for main/worker sidecars. Do not read or create the payload. Document full-file replacement and manual restart after changes. |
| Pod DNS settings, 0.4.0 | Port | Chart 1.10.1 renders `dnsConfig` for all three roles. Add an optional typed object; no AWS `ndots` default or local DNS sidecar. |
| Global V8 heap ceiling, 0.4.0 | Port | Add optional `NODE_OPTIONS` ownership, reserved only when the dedicated input is set. Size against the smallest n8n container, not total pod or runner memory. |
| Credential overwrite Secret, 0.4.0 | Port | Add reference-only read-only mounts and `CREDENTIALS_OVERWRITE_DATA_FILE` on all n8n roles. No plaintext overwrite variable, Secret data source, or automatic rotation claim. |
| Supplied n8n encryption key, 0.3.0 | Adapt | Google already supports an entire external core Secret, but always generates the key on its managed-core path. Add direct sensitive `n8n_encryption_key`, mutually exclusive with `existing_n8n_core_secret_name`; keep that honest core-Secret name instead of AWS's misleading key-only reference name. |
| License key no longer inline in Helm, 0.3.0 | Port | Google still passes direct `license.activationKey`. Wrap the direct value in a module Secret and use `license.existingSecret`; existing external Secret references remain unread. State exposure remains for direct values. |
| Extra ConfigMap/Secret/PVC volumes and mounts, 0.3.0 | Adapt | Google only supplies an internal `redis-ca` mount. Add typed external references and merge them with that CA and credential-overwrite mounts. Reject reserved names and overlapping protected paths. No PVC or ConfigMap provisioning. |
| Community registry, task execution timeout, unverified packages, compression limits, 0.3.0 | Port | Five inputs are missing. Preserve optional runtime defaults for security controls; distinguish runner task execution timeout from existing task acceptance timeout. Document registry entitlement and authentication exposure. |
| Custom images, pull Secrets, runner image tags, extension paths, 0.2.0/0.3.0 | Existing | `variables.tf` and `n8n.tf` already implement them, including the distinct module-owned ServiceAccount and Workload Identity annotation. Extend the extension-path diagnostic to accept a covering external mount. Preserve Google's independent runner repository and image pull policy controls. |
| Metrics toggle, tracing, log streaming, templates, personalization, community reinstall/loading, 0.1.0/0.2.0 | Existing | Dedicated variables and shared environment wiring exist. Regression-test these while extending the environment list; no default changes. |
| External Secrets runtime and cloud vault IAM, 0.3.0 | Existing | Google's secret-level IAM allow-list and Workload Identity replace AWS Secrets Manager IAM. Keep vault configuration in n8n's UI; do not add AWS `kms:Decrypt` to Google workload permissions. |
| Execution-data object storage, 0.3.0 | Existing | Google already has `database`/`s3` modes backed by GCS HMAC, version warning, and no filesystem mode. Do not copy AWS throughput claims or change the database default. |

## Routing, scaling, and observability

| AWS feature or fix | Decision | Google evidence and planned action |
| --- | --- | --- |
| Editor/OAuth base URL and current webhook variable, 0.4.0 | Port | `N8N_EDITOR_BASE_URL` is reserved but never emitted; only legacy `WEBHOOK_URL` is set. Set the editor URL from `n8n_fqdn` and both webhook variable names from one effective URL. Test distinct hosts and document OAuth registration changes. |
| Additional full-route hostnames, 0.3.0 | Adapt | Add `n8n_additional_domains`, with Google-managed certificate, Cloud DNS, self-signed SAN, external TLS, and no-ingress ownership behavior. Aliases do not change the canonical editor or webhook URL. |
| Ingress annotations, 0.3.0 | Adapt | Add `ingress_annotations` but protect module-owned class, address, and certificate annotations. Do not copy unsafe unrestricted last-write-wins overrides that can detach Google-managed resources. |
| Public webhook/private editor split ingress, 0.3.0 | Adapt | Use `create_ingress=false` with a new caller-owned GKE example. Internal regional IP, proxy-only subnet, firewall, and TLS differ from ALB. Public ingress must have no main-service catch-all. Root `ingress_scheme` is not added to a module whose managed ingress is explicitly a global external load balancer. |
| Five webhook endpoint families, 0.3.0 | Existing | Managed ingress and route outputs already include `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, `/mcp`. Verify both canonical and alias routes and the split example. |
| Source restrictions and SSL policy, 0.3.0 | Existing | Cloud Armor and FrontendConfig replace ALB CIDRs, prefix lists, and TLS policy. Preserve Google's log4j deny rule. Chart 1.10.1 supports common Service annotations on both main and webhook Services; add rendering evidence instead of relying on the current smoke-test caveat. |
| Shared Redis namespace and reserved command prefix, 0.3.0 | Port fix | Google sets `redis.prefix` and KEDA queue keys but omits `N8N_REDIS_KEY_PREFIX` from both wiring and reserved names. Set both Redis namespaces when a prefix is supplied; leave distinct upstream defaults alone when null. |
| Opt-in Redis exporter, 0.4.0 | Adapt | New private Deployment/Service. Share endpoint, ACL username, Secret, TLS, and exact waiting/active keys. Unlike AWS, Memorystore needs its private service CA mounted. Keep verification on; no monitoring stack installation. |
| Helm upgrade replica reset to configured floors, 0.3.0 | Existing, limitation remains | Google already uses selected scaler minima or fixed counts. Chart 1.10.1 still emits Deployment replicas unconditionally: an upgrade can reset replicas above the floor. Document and test the bounded behavior; do not promise fully non-clobbering upgrades or add an unreviewed post-renderer/chart fork. |
| Webhook scale-up stabilization, 0.3.0 | Port | Add the validated setting to Google's standalone webhook HPA, default 0. Respect `n8n_webhook_hpa_enabled=false`. |
| Replica validation and capacity checks, 0.3.0 | Adapt | Google has CPU and memory estimates with regional reserves, but lacks validation on several scaler floors/ceilings and resource quantities. Validate the accepted quantity grammar and bounds; share the effective main ceiling with single-main behavior. Do not copy AWS maximum defaults 6/8 or AWS bin-packing assumptions. |
| Node desired-size autoscaler conflict, 0.3.0 | Existing by design | Google's node pool configures autoscaling bounds without a Terraform-controlled `node_count`. Do not introduce an AWS-style desired count or unnecessary `ignore_changes`. |

## Google infrastructure and verification

| AWS feature or fix | Decision | Google evidence and planned action |
| --- | --- | --- |
| Configurable EKS root disk, 0.4.0 | Existing | `gke_node_disk_size_gb` already defaults to 100 and reaches `node_config.disk_size_gb`. Add validation and example passthrough where missing; document GKE plan/recreation risk without copying EKS ForceNew claims. |
| Configurable database backup retention, 0.3.0 | Adapt | Cloud SQL backups/PITR are enabled but retention is not exposed. Add optional backup **count** and transaction-log retention using [Google provider fields][sql-provider]. Keep backup enablement and existing omitted defaults. |
| Redis daily snapshot retention, 0.3.0 | Adapt, not equivalent | Memorystore [RDB persistence][rdb] supports periodic automatic recovery from the latest successful snapshot, not ElastiCache's historical snapshot retention count. Add opt-in RDB settings; document memory/latency risk, stale recovery, and export/import for independent backups. Do not represent this as queue-safe point-in-time recovery. |
| Database query logging switch, 0.3.0 | Adapt | Cloud SQL Query Insights is already enabled but is not the same as PostgreSQL statement logging. Add opt-in DDL/slow-query flags, with payload-risk guidance and external-instance ignored-input checks. Do not copy `rds.force_ssl`. |
| Immediate RDS and Redis apply controls, 0.4.0 | Exclude flags, adapt docs | Neither checked Google resource documents `apply_immediately`. [Cloud SQL maintenance][sql-maintenance] and [Memorystore maintenance][redis-maintenance] have separate policies. Document provider-appropriate modification/maintenance checks; do not manufacture a deferred-apply toggle or change existing maintenance windows just for parity. |
| RDS/Aurora PostgreSQL 18.4 defaults, 0.3.0 | Exclude automatic bump | Google uses `POSTGRES_<major>`, not RDS minor versions. The checked provider 6.50 docs list through 17, not 18; this is insufficient evidence to promise 18 compatibility. Keep current default and document deliberate supported-major selection through existing `postgres_version`. Engine modernization requires a separate compatibility assessment, not copied AWS version/ignore-change behavior. |
| Large-tier AWS load-tested sizes and results, 0.4.0 | Adapt guidance only | Google has no Aurora/PgBouncer large example and is explicitly not scale-validated. Keep GKE/Cloud SQL/Memorystore sizes; correct the stale worker-maximum prose (160 versus actual 80). Explain lazy per-process pools, aggregate limits, DNS, heap, disk, and pruning observations without claiming AWS measurements apply to Google. |
| Cloud/network/KMS/resource ownership, restore, external secrets, controllers, 0.3.0 | Existing | Google full-stack modularity already covers these with native GKE/Workload Identity/PSA and broader ownership switches. Preserve fully customer-managed no-resource tests and explicit service-key ownership. |
| EKS controller IAM, LBC webhook path/subnet tags, Pod Identity, EBS CSI, CloudWatch cleanup, AWS permissions boundaries and provider upgrades | Exclude | AWS-specific resources and failure modes. GKE supplies native controllers and logging; a direct name-for-name port would be incorrect. No speculative Google IAM abstraction. |
| AWS historical resource-address `moved` blocks, 0.3.0 | Exclude literal port | AWS addresses cannot migrate Google state. Follow Google's stated pre-release migration contract and explicitly inventory any new address changes. Breaking permission does not justify unrelated renames. |
| Helm rendering CI and topology smoke checks, 0.4.0 | Port | Google's CI has no render job. Add checks against the actual pinned chart and shared module-computed value fragments, covering all affected roles and ownership paths. |
| Blocking curated Checkov and matching local/CI checks, 0.3.0 | Adapt | Google still runs `soft_fail=true`. Inventory and fix Google findings, document genuine exceptions narrowly, then make the gate blocking. Keep Terraform 1.9.8 coverage; AWS's 1.11 floor was driven by AWS tests, not a Google requirement. |
| Customer-managed examples, docs generation, naming/community files | Existing | Google already covers all nine examples plus the public controller module/direct example in CI. Add new example coverage to every job and fix the unsafe chained-`cd` local instructions as part of verification documentation. |

## Explicit limitations retained

No community-edition topology, automatic key rotation, Secret/ConfigMap payload inspection, bundled Prometheus/Grafana, GKE load-test claim, chart fork, or forced cloud major-version upgrade is introduced. Redis recovery can lose or replay work; Helm upgrades can reset replicas to floors; external Secret and ConfigMap updates need deliberate restarts. These are documented boundaries, not silently completed features.

[release]: https://github.com/n8n-io/terraform-aws-n8n/releases/tag/0.4.0
[changelog]: https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/CHANGELOG.md
[inputs]: https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/variables.tf
[aws-n8n]: https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/n8n.tf
[aws-scaling]: https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/scaling.tf
[aws-exporter]: https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/observability.tf
[aws-chart-test]: https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/tests/scripts/check-main-chart.sh
[sql-provider]: https://github.com/hashicorp/terraform-provider-google/blob/v6.50.0/website/docs/r/sql_database_instance.html.markdown
[rdb]: https://docs.cloud.google.com/memorystore/docs/redis/about-rdb-snapshots
[sql-maintenance]: https://docs.cloud.google.com/sql/docs/postgres/maintenance
[redis-maintenance]: https://docs.cloud.google.com/memorystore/docs/redis/find-and-set-maintenance-windows
