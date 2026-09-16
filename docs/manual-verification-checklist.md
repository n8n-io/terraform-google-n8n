# Manual Google Cloud verification checklist

This checklist covers runtime-only scenarios that mocked `terraform test`
providers, `tests/scripts/check-n8n-chart.sh`, and `tests/scripts/smoke-test.sh`
cannot prove: real GKE reconciliation, Google Cloud TLS handshakes, Memorystore
failover, and n8n licensing. It supplements, and does not replace, the
automated suites at the module root, in `modules/controllers`, and in every
`examples/*` directory.

**Status of every item below is "Not run" until an operator actually performs
it against a real deployment.** Implementation of
`add-google-parity-through-aws-0-4-0` does not require running this
checklist; delivering it, with every item explicitly marked not run, is what
gates completion (see `openspec/changes/add-google-parity-through-aws-0-4-0/tasks.md`,
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
| 1 | Single-main rollout and drain | Not run |
| 2 | Return to multi-main | Not run |
| 3 | Credentials-overwrite Secret rotation | Not run |
| 4 | Task-runner custom launcher ConfigMap rotation | Not run |
| 5 | Restored/cloned database encryption-key continuity | Not run |
| 6 | Separate-host OAuth callback | Not run |
| 7 | Alias hostname TLS coverage | Not run |
| 8 | Split-ingress public/private route isolation | Not run |
| 9 | Redis command/Bull prefix isolation transition | Not run |
| 10 | Redis exporter TLS and metrics | Not run |
| 11 | Memorystore RDB persistence recovery | Not run |
| 12 | n8n Enterprise license activation and single-main entitlement | Not run |
| 13 | GKE Dataplane V2 migration | Not run |
| 14 | GCS access-log delivery | Not run |

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

**Status: Not run for the new two-stage procedure.** Render and mocked tests do
not prove ordering or schedule safety. The standard smoke test checks the final
multi-main state only, not the election-enabled one-replica intermediate state.

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
