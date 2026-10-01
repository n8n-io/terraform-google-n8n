# Manual Google Cloud verification checklist

This checklist covers runtime-only scenarios that mocked `terraform test`
providers, `tests/scripts/check-n8n-chart.sh`, and `tests/scripts/smoke-test.sh`
cannot prove: real GKE reconciliation, Google Cloud TLS handshakes, Memorystore
failover, and n8n licensing. It supplements, and does not replace, the
automated suites at the module root, in `modules/controllers`, and in every
`examples/*` directory.

**Status of every item below is "Not run" until an operator actually performs
it against a real deployment.** Items marked otherwise were run on a disposable
`examples/small` deployment (n8n 2.38.7, chart 1.10.1, Terraform 1.9.8) on
2026-09-15/16; the result column states what was and was not covered. Evidence
stays with the change record, not in this repository. Implementation of
`add-google-parity-through-aws-0-4-0` does not require running this
checklist; delivering it, with every item explicitly marked not run, is what
gates completion (see
`openspec/changes/archive/2026-09-14-add-google-parity-through-aws-0-4-0/tasks.md`,
section 26). Do not mark an item "passed" without actually performing it, and
do not run destructive items (drains, restarts, snapshot recovery, license
changes) against a production deployment.

## How to use this checklist

1. Provision a disposable Google Cloud project or a non-production example
   (`examples/small` is sufficient for every item below except split ingress
   and large-tier sizing).
2. Work through each item, record the actual result (pass/fail and any
   deviation from "Expected result"), and keep the evidence (command output,
   screenshots) with your change record.
3. Destructive items are called out individually; do not run them against a
   deployment with real user data.
4. Tear down the disposable environment afterward (see
   [`destroy-cleanup.md`](./destroy-cleanup.md)).

| # | Item | Status |
| --- | --- | --- |
| 1 | Single-main rollout and drain | Partial (see section) |
| 2 | Return to multi-main | Partial (see section) |
| 3 | Credentials-overwrite Secret rotation | Not run |
| 4 | Task-runner custom launcher ConfigMap rotation | Not run |
| 5 | Restored/cloned database encryption-key continuity | Not run |
| 6 | Separate-host OAuth callback | Not run |
| 7 | Alias hostname TLS coverage | Not run |
| 8 | Split-ingress public/private route isolation | Not run |
| 9 | Redis command/Bull prefix isolation transition | Not run |
| 10 | Redis exporter TLS and metrics | Not run |
| 11 | Memorystore RDB persistence recovery | Partial (see section) |
| 12 | n8n Enterprise license activation and single-main entitlement | Partial (see section) |
| 13 | GKE Dataplane V2 migration | Not run |
| 14 | GCS access-log delivery | Passed (see section) |
| 15 | KEDA worker scale-out and scale-in | Passed (see section) |

## 1. Single-main rollout and drain

**Safety prerequisite:** disposable environment; interrupts the editor, REST
API, and scheduled triggers by design. Requires an n8n Enterprise license
edition that supports single-main.

1. Deploy multi-main (default), confirm the app is healthy via
   `tests/scripts/smoke-test.sh`.
2. Set `n8n_main_hpa_min_replicas = 1` (or `n8n_main_fixed_replicas = 1` with
   the HPA disabled) and `terraform apply`.
3. **Expected result:** `n8n-main` scales to exactly 1 replica, rollout
   strategy is `Recreate`, the main PodDisruptionBudget's `minAvailable` is
   `0`, and `multiMain.enabled` is `false` (`kubectl get deployment n8n-main -o
   jsonpath='{.spec.strategy.type}'`, `kubectl get pdb -n <namespace>`).
4. Trigger a rollout (e.g. `kubectl rollout restart deployment/n8n-main -n
   <namespace>`) and confirm the editor and REST API are briefly unreachable
   during the recreate, then recover.
5. Confirm scheduled triggers still fire once the single main pod is ready
   again.

**Status: partial.** Steps 1 to 3 passed twice on a disposable deployment:
once through `n8n_main_hpa_min_replicas = 1` (Recreate, PDB 0, HPA clamped to
1/1) and once through `n8n_main_hpa_enabled = false` with
`n8n_main_fixed_replicas = 1` (no main HPA rendered). The Recreate swap
produced about 22 to 36 seconds of editor/API unavailability in each run;
worker and webhook-processor pods were unaffected when only the main template
changed. Step 4 (`rollout restart`) and node drains were not run. Step 5 was
observed only as a side effect of the scheduling test in item 2.

## 2. Return to multi-main

**Safety prerequisite:** disposable environment, multi-main license, pinned
images, explicit context/namespace verification, and separate approval for each
apply. No real workflows, traffic, or data. Do not combine election activation
and a replica increase. For the scheduling regression, separately authorize one
harmless test schedule; other submissions and queues must remain idle.

1. Follow the [two-stage procedure](./upgrading-n8n.md#returning-to-multi-main).
   Start with a converged election-disabled single main. Record pod UIDs,
   process start/stop timestamps, ReplicaSet counts, election flags, leadership
   logs, and HTTPS health throughout both applies, not only afterward.
2. Stage one: set `n8n_main_leader_election_enabled = true` while holding the
   selected count at one. **Expected result:** old process exits before the
   replacement starts, exactly one election-enabled main becomes Ready, strategy
   remains `Recreate`, PDB minimum remains 0, and a managed main HPA remains
   min/max 1/1. Chart `multiMain.enabled` stays false; the literal election flag
   comes from module-owned `config.extraEnv` on all three n8n roles. Verify
   worker/webhook health and role behavior, the license, queue execution, and
   convergence. Above one replica, verify that the staging literal disappears
   and the chart's main-only ConfigMap election reference takes over.
3. Stage two: keep election explicitly true and separately increase replicas.
   **Expected result:** no election-disabled pod exists before scaling begins;
   every main started during scaling is election-enabled. PDB minimum returns
   to 1, strategy returns to the chart default, and managed HPA limits return
   to their configured values. Both mains, workers, webhooks, and queue
   execution must recover; final Terraform plan must converge.
4. In an approved scheduling regression, use one harmless schedule with a unique
   test identifier and persist each scheduled tick's timestamp and execution ID.
   Compare executions per tick before, during, and after both stages. Record
   downtime-related missed ticks separately; do not infer exactly-once behavior
   from a successful final execution. Any duplicate tick or concurrent
   election-disabled main fails the transition test.
5. Repeat under separately approved scheduling/capacity pressure in the
   disposable environment to expose delayed replacement. Repeat for managed HPA
   and fixed-replica ownership. Delete the test workflow and its executions and
   verify cleanup. Do not use production node drains or failover for this test.

**Status: partial.** The two-stage procedure passed with an idle workload on
both ownership paths (managed HPA 1/1 to 2/20, and fixed replicas 1 to 2 with
the HPA disabled). In every run the old election-disabled process exited before
its replacement started, exactly one election-enabled main became Ready at stage
one (all three roles rolled once because the literal flag is emitted through
`config.extraEnv`), and no election-disabled pod existed during the scale-up.
Observed detail worth knowing: during the stage-two scale-up Kubernetes first
scaled the *previous* ReplicaSet (the stage-one, election-enabled template) to
two before the new ReplicaSet took over. That controller behaviour is exactly
what made the old one-step conversion unsafe; with stage one applied first it is
harmless, which is why the two stages must not be combined.

Not established: the active-schedule regression (step 4) was run three times on
the managed-HPA path. Baseline and stage-one windows showed no duplicate or
missing ticks apart from the Recreate gap, but the stage-two window was stopped
each time under the anomaly rule because the new leader logged
`EntityMetadataNotFoundError: No metadata for "Agent" was found` from
`AgentTaskService.reconnectAll` during leader takeover on n8n 2.38.7 (reproduced
again on the fixed-replica path). Ordinary scheduling continued, but a clean
continuous pass was not collected. This is an application issue with the
default module set (Instance AI enabled, Agents disabled), not a Terraform
behaviour; report it upstream rather than working around it here. Step 5
(capacity pressure) was not run.

## 3. Credentials-overwrite Secret rotation

**Safety prerequisite:** disposable environment; this is a destructive
restart of all three n8n deployments.

1. Set `n8n_credentials_overwrite_secret_ref` to reference an existing Secret
   key and `terraform apply`. Confirm `CREDENTIALS_OVERWRITE_DATA_FILE` is set
   and readable on all three roles (`tests/scripts/smoke-test.sh` checks
   this).
2. Update the referenced Secret's data out of band (`kubectl create secret ...
   --dry-run=client -o yaml | kubectl apply -f -` or `kubectl edit secret`).
3. **Expected result:** `terraform plan` shows no diff (the module only reads
   the reference, not the Secret's contents), so no automatic rollout occurs.
4. Manually restart all three deployments (`kubectl rollout restart
   deployment/n8n-main deployment/n8n-worker
   deployment/n8n-webhook-processor -n <namespace>`) and confirm the new
   overwrite values take effect (e.g. a credential type covered by the
   overwrite behaves per the new values in the n8n UI).

## 4. Task-runner custom launcher ConfigMap rotation

**Safety prerequisite:** disposable environment; restarts main and worker.

1. Set `n8n_task_runner_custom_config` referencing an existing ConfigMap and
   `terraform apply`. Confirm the `task-runner-config` volume, backed by that
   ConfigMap, is mounted on the main/worker pods
   (`kubectl get pod <pod> -o jsonpath='{.spec.volumes[?(@.name=="task-runner-config")]}'`).
2. Update the ConfigMap's data out of band.
3. **Expected result:** `terraform plan` shows no diff.
4. Manually restart `n8n-main` and `n8n-worker` and confirm the launcher
   picks up the new configuration (check runner sidecar logs for the new
   allow-list/config values).

## 5. Restored/cloned database encryption-key continuity

**Safety prerequisite:** disposable environment; use a throwaway Cloud SQL
clone or restored instance, never a production database.

1. On an existing deployment, capture the sensitive `n8n_encryption_key`
   output (`terraform output -raw n8n_encryption_key`) and back it up
   securely.
2. Create a Cloud SQL clone or restore a backup into a new instance pointed
   at by a fresh `terraform apply` (new `examples/*` directory or
   `postgres_restore_source`, per your setup).
3. Set `n8n_encryption_key` to the value captured in step 1 on the new apply.
4. **Expected result:** the new deployment's n8n instance can decrypt
   existing credentials created before the clone/restore (verify by opening a
   credential created on the source deployment and confirming it loads
   without a "credentials could not be decrypted" error).
5. Confirm no restore-source validation is bypassed: an unset
   `n8n_encryption_key` combined with a restore source still produces the
   existing missing-key diagnostic.

## 6. Separate-host OAuth callback

**Safety prerequisite:** disposable environment; needs a real OAuth2
application (e.g. Google, GitHub) you control, and DNS you own for the
webhook host.

1. Set `n8n_fqdn` to the editor host and `n8n_webhook_url` to a distinct
   webhook host, `terraform apply`.
2. Confirm `N8N_EDITOR_BASE_URL=https://<n8n_fqdn>` on all roles (check pod
   env).
3. Register an OAuth2 credential in n8n and confirm the redirect URI n8n
   presents is `https://<n8n_fqdn>/rest/oauth2-credential/callback`, not the
   webhook host.
4. **Expected result:** completing the OAuth2 authorization flow against the
   registered redirect URI succeeds.

## 7. Alias hostname TLS coverage

**Safety prerequisite:** disposable environment; needs DNS you control for
each alias.

1. Set `n8n_additional_domains` to one or more aliases you control DNS for,
   with `tls_mode = "google_managed"` (default), `terraform apply`.
2. Wait for the ManagedCertificate to reach `Active`
   (`kubectl get managedcertificate -n <namespace>`); this can take longer
   with multiple domains.
3. **Expected result:** every hostname in the `n8n_ingress_hosts` output
   serves a valid certificate covering that host and responds `200` on
   `/healthz` (`tests/scripts/smoke-test.sh` checks reachability
   automatically; verify certificate validity separately with `openssl
   s_client -connect <host>:443 -servername <host> </dev/null 2>/dev/null |
   openssl x509 -noout -subject -ext subjectAltName`).
4. Repeat for `tls_mode = "self_signed"` and confirm the self-signed
   certificate's SAN list includes every alias, and for a caller-supplied
   `tls_mode = "secret"`/`"custom"` certificate, confirm you provisioned it to
   cover every alias yourself (the module does not inspect it).

## 8. Split-ingress public/private route isolation

**Safety prerequisite:** disposable environment; needs a GKE cluster with a
proxy-only subnet provisioned (see `examples/split-ingress/README.md`) and
both public and private (VPN, interconnect, or bastion) network access to
test from.

1. Apply `examples/split-ingress` with `create_ingress = false`.
2. From a public network path, confirm the public ingress serves only the
   five webhook route families (`/webhook`, `/webhook-waiting`, `/form`,
   `/form-waiting`, `/mcp`) and returns no route to the main editor service
   (a request to `/` on the public address should not reach `n8n-main`).
3. From a private network path (VPN/interconnect/bastion reaching the
   internal load balancer), confirm the internal ingress serves the same
   five webhook families **and** the main editor route (`/`).
4. Verify the private host's certificate with a client that trusts its CA,
   without skipping TLS verification. Confirm port 80 does not serve the
   application or an HTTP redirect; the private Ingress is HTTPS-only.
5. **Expected result:** the public address never exposes the editor UI or
   REST API; the internal address exposes both editor and webhook routes over
   HTTPS, with no Ingress reconciliation errors.

## 9. Redis command/Bull prefix isolation transition

**Safety prerequisite:** disposable environment; this is a destructive queue
transition. Drain the queue first (let in-flight executions finish, then
scale workers to 0) before changing the prefix on a deployment with real
queued work.

1. On a running deployment, set `redis_key_prefix` to a new value and
   `terraform apply`.
2. **Expected result:** the Helm upgrade restarts all three n8n deployments
   together (not a rolling, partial restart), and after the restart,
   `QUEUE_BULL_PREFIX` and `N8N_REDIS_KEY_PREFIX` on worker pods both show the
   new value (`tests/scripts/smoke-test.sh` checks they match automatically).
3. Confirm no job queued under the old prefix is silently picked up
   (workers under the new prefix do not see the old prefix's queue keys);
   this is expected, not a bug, drain before transitioning on a real
   workload.

## 10. Redis exporter TLS and metrics

**Safety prerequisite:** none beyond a running deployment; read-only.

1. Set `redis_exporter_enabled = true` and `terraform apply`.
2. `kubectl port-forward -n <namespace> svc/<redis_exporter_service_name>
   9121:9121` and `curl -s localhost:9121/metrics`.
3. **Expected result:** metrics are returned (`redis_up 1`), and for a
   module-managed Memorystore instance (which enforces TLS), the exporter
   logs show a successful TLS connection verified against the mounted
   Memorystore service CA, not a bypassed/insecure connection.
4. For external Redis, confirm the exporter connects using system trust and
   the effective address's certificate, per the existing external connection
   contract.
5. Confirm the exporter reads the exact Bull queue keys (respecting any
   `redis_key_prefix`), not a keyspace scan, by checking its logs or metrics
   output for the expected key names.

## 11. Memorystore RDB persistence recovery

**Safety prerequisite:** disposable environment; this exercises an actual
Memorystore restart/failover, which is disruptive and can replay stale or
duplicate queued jobs. Do not run against a deployment with real user data.

1. Set `redis_persistence_enabled = true` with a short
   `redis_rdb_snapshot_period` (e.g. `ONE_HOUR`) and `terraform apply`.
2. Queue some Bull jobs, wait for at least one snapshot period to elapse.
3. Trigger an unplanned Memorystore restart through a supported Google Cloud
   maintenance/failover action (see Memorystore documentation for your tier;
   do not attempt to force this through the module).
4. **Expected result:** Redis recovers from the last RDB snapshot, not from
   empty state; confirm this is last-snapshot recovery (some in-flight work
   since the snapshot may be lost or replayed as stale/duplicate), not a
   numbered backup-retention restore point.
5. Set `redis_persistence_enabled = false`, leaving the previous schedule
   inputs set for this test. Confirm the plan changes `persistence_mode`
   from `RDB` to `DISABLED`, with only the expected ignored-schedule warning,
   then apply. Inspect the instance in Google Cloud and confirm persistence
   is disabled. A subsequent plan must not try to re-enable it.
6. Set the switch back to true, review the schedule, and apply. Confirm RDB
   persistence and the configured schedule return. This tests both
   transitions, which fresh-state mocked plans cannot prove.

**Status: partial.** Steps 1, 5, and 6 passed: each direction was a single
in-place `google_redis_instance` update (`DISABLED` to `RDB`/`ONE_HOUR` and
back) with no Helm or pod change and no HTTPS disruption. One hourly snapshot
was confirmed complete through Cloud Monitoring (`rdb/snapshot/last_success_age`
resetting, `attempt_count` 1, `in_progress` false), with the caveat that this
is service-reported completion, not a restored-contents check. Steps 2 to 4
(queued jobs plus an actual restart/failover recovery) were not run. Disabling
persistence deletes the managed snapshots; accept that explicitly.

## 12. n8n Enterprise license activation and single-main entitlement

**Safety prerequisite:** needs a real n8n Enterprise license key.

1. Set `n8n_license_key` (or `n8n_license_key_secret_ref`) and
   `terraform apply`. Confirm no literal license key appears in
   `helm get values n8n -n <namespace>` output (the managed `n8n-license-secret`
   Secret should back `license.existingSecret` instead;
   `tests/scripts/smoke-test.sh` checks the Secret's existence, never its
   contents).
2. Activate the license in the n8n UI (**Settings → License**) and confirm
   the edition's entitlements appear (e.g. single-main availability, if your
   edition includes it).
3. **Expected result:** a license edition without single-main entitlement
   fails to run with `n8n_main_hpa_min_replicas = 1` /
   `n8n_main_fixed_replicas = 1` in n8n itself (not enforced by Terraform);
   confirm the module does not claim to parse or validate license contents,
   and that single-main entitlement alone does not unlock External Secrets,
   log streaming, the custom package registry, or object-storage
   entitlements, which depend on the edition's other features.

**Status: partial.** With one Enterprise key: the key reached the pods only
through the managed `n8n-license-secret` reference (no literal in Helm values
or pod env), activation succeeded, multi-main and single-main both ran, and the
floating seat survived every main restart with
`N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false`. Step 3 (an edition without
single-main entitlement) and the other entitlement boundaries were not tested.

### 12a. Offline license activation (`n8n_license_cert_secret_ref`)

**Safety prerequisite:** a real n8n offline license certificate (`N8N_LICENSE_CERT`),
in a caller-managed Kubernetes Secret.

1. Set `n8n_license_cert_secret_ref` (and `n8n_license_key = null`), ideally
   with egress to n8n's license server blocked, and `terraform apply`.
   Confirm `kubernetes_secret.n8n_license` is not created, and that
   `helm get values n8n -n <namespace>` shows `license.enabled: true` with
   an inert `existingSecret` block (empty `name`) and an empty
   `activationKey` - that is the expected shape on this path, not a sign of
   a leaked key - and that `kubectl -n <namespace> exec deploy/n8n-main -- printenv`
   shows no `N8N_LICENSE_ACTIVATION_KEY`.
2. Confirm activation from **Settings → License** or
   `kubectl -n <namespace> exec deploy/n8n-main -- n8n license:info`, with no
   outbound call to n8n's license server.
3. Confirm multi-main still runs (2+ main replicas) on the certificate path,
   since `license.enabled` staying `true` is what keeps
   `N8N_MULTI_MAIN_SETUP_ENABLED` rendering.
4. Roll the main deployment and confirm replacement pods stay licensed with
   no re-activation round trip.
5. Rotate the certificate (update the caller-managed Secret's payload) and
   restart `n8n-main`/`n8n-worker`/`n8n-webhook-processor`; confirm the new
   certificate takes effect, since the module never reads the Secret's value
   and cannot detect a payload change itself.

**Status: not yet run.** Requires a real offline license certificate from
n8n; not available in this environment.

## 13. GKE Dataplane V2 migration

**Safety prerequisite:** disposable deployment created with the previous
module version and `LEGACY_DATAPATH`. Cluster replacement is destructive;
never use production data for this rehearsal.

1. Follow the [GKE migration procedure](./upgrading-n8n.md#gke-dataplane-v2-requires-cluster-replacement).
   Save the reviewed plan showing the cluster replacement and confirm that
   the database, Redis, GCS, and VPC resources are retained.
2. Record the separate deletion-protection change, load balancer cleanup,
   cluster replacement, and provider reconnection steps actually required.
   Do not record a one-apply migration as supported unless it succeeds.
3. Restore caller-managed Kubernetes objects and verify the recovered n8n
   deployment can decrypt existing credentials and execute a workflow.
4. **Expected result:** the new cluster uses `ADVANCED_DATAPATH`, all workload
   and ingress checks pass, deletion protection is restored, and a final plan
   has no unexpected changes. Record the observed downtime.

## 14. GCS access-log delivery

**Safety prerequisite:** disposable deployment with a module-managed bucket;
use a non-sensitive test object.

1. Confirm the log destination is the module-managed access-log bucket and
   its IAM policy grants `roles/storage.objectCreator` to
   `group:cloud-storage-analytics@google.com`.
2. Write and read the test object in the binary-data bucket. Wait for Cloud
   Storage's asynchronous log delivery, then inspect the destination for
   usage-log objects corresponding to the test requests. Follow
   [Cloud Storage usage-log guidance](https://docs.cloud.google.com/storage/docs/access-logs)
   for delivery timing and request coverage.
3. **Expected result:** log objects arrive in the dedicated destination. A
   configured logging block or passing IAM assertion alone is not proof of
   delivery. With `create_gcs_bucket = false`, confirm the plan creates no
   logging bucket or log-delivery IAM grant.

**Status: passed** for the module-managed bucket path. A 1024-byte webhook
upload was stored through the S3-compatible driver, read back by a queue
worker, and verified byte-for-byte from the bucket. Usage-log objects arrived
in the dedicated destination within about a day, and five distinct requests
(SDK PUT and GET, operator generation-pinned GET, metadata GET, DELETE) were
matched to the exact test object by bucket and object name. The delivered CSV
carries an extra trailing `cached_response_size` column beyond the published v0
schema; parsers should tolerate it. The `create_gcs_bucket = false` negative
check was not run.

## 15. KEDA worker scale-out and scale-in

**Safety prerequisite:** disposable environment with an idle queue; a few
dozen short jobs only. Needs an API key for the disposable workflow and exact
cleanup of the workflow and its executions.

1. Create a disposable webhook workflow whose body keeps the Bull job active
   for about two minutes, for example three `Wait` nodes of 40 seconds each
   (waits under 65 seconds run in-process; longer waits suspend the execution
   and leave the active list, which would not exercise the scaler).
2. Submit one calibration job and confirm `bull:jobs:active` stays at 1 for
   its duration and the execution succeeds. Then submit enough jobs to exceed
   `n8n_worker_keda_jobs_per_replica` (default 5) two to three times over,
   for example 12, while recording queue depths, the KEDA HPA's desired and
   current replicas, and worker pod identities every few seconds.
3. **Expected result:** desired worker replicas follow `ceil(active / 5)`
   within one polling interval (15 seconds); new workers become Ready on
   existing nodes; every submission maps to exactly one successful execution;
   after the queue drains, replicas return to `n8n_worker_keda_min_replicas`
   after the Kubernetes HPA default 300-second downscale stabilization (KEDA's
   `cooldownPeriod` only governs scale-to-zero).
4. Note whether the additional workers processed any jobs. With the defaults
   they will not: effective worker concurrency is 100 (see
   `n8n_worker_concurrency`), so one worker absorbs the whole test load.
5. Delete the workflow and its executions and verify both are absent.

**Status: passed** on a disposable deployment with n8n 2.38.7: 13 jobs drove
desired replicas 1 -> 2 -> 3 within 25 seconds of load, three workers Ready,
13/13 successful executions with no duplicates, scale-in to one worker 285
seconds after the queue drained, no restarts, no cluster autoscaling, and the
original worker processed every job (the two extra workers took none).
