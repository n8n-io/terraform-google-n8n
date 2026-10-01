# Worker pools example (EARLY ALPHA)

Sizing-equivalent to [`small`](../small/) apart from `gke_node_max_per_zone`, with one topology change: three labelled **worker pools** run beside the chart's own unlabelled worker deployment, each with its own replica bounds, sizing and autoscaler.

`gke_node_max_per_zone` goes from the module's own default of 4 to 6 (GKE places a regional node pool across 3 zones, so roughly 12 to 18 `e2-standard-4` nodes). Pools are additional autoscalers on the same node pool rather than a redistribution of the ceilings already there, so their pods have to fit alongside the main, default-worker and webhook maxima. See the comment on `gke_node_max_per_zone` in `main.tf` for the arithmetic.

n8n's worker pools pin a project's executions to a named set of workers. A worker started with `N8N_WORKER_POOL_NAME=<name>` stops consuming the default `jobs` Bull queue and consumes `jobs-<name>` instead; a project assigned to that pool has its executions enqueued there. Assign a project to a pool in the n8n UI under **Project, Settings, Worker Pools**.

Use this example when some executions need different hardware or isolation: heavier jobs on bigger workers, or one team's projects kept off the shared pool.

> **Early Alpha, subject to change without notice.** Worker pools are an alpha n8n feature, and the chart side that renders them (`queueMode.workerGroups`) is merged to a preview branch, not released. This example, the module's `n8n_worker_pools` input, and the guidance below may all change to track either upstream feature. What it needs today:
>
> - **n8n 2.39.0 or later** on the image. That is the first release that reads `N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME`; an older image accepts both and ignores them. The preview chart's own default tag may sit below that, so pin `n8n_image_tag` explicitly rather than trusting the chart's default.
> - **A licence carrying `feat:workerPools`.** Without it a worker started with `N8N_WORKER_POOL_NAME` exits 1 with `worker pools are not licensed`, every pool pod crash-loops, and the Helm release fails its wait and is rolled back by `atomic`, so the apply fails. Terraform cannot see entitlements at plan, so the log line is the diagnosis: `kubectl -n n8n logs -l n8n.io/worker-pool=<pool> -c n8n-worker --previous | grep licensed`. If the entitlement is **added to a key that has already activated**, the pods keep loading the old certificate cached in the database (`settings` table, key `license.cert`) and keep failing. Delete that row and restart the n8n deployments so each process re-activates; a `terraform apply` alone does not clear it.
> - **A Helm chart that renders `queueMode.workerGroups`.** No published chart *release* carries it (the newest, 1.13.0, does not); the feature is [n8n-io/n8n-hosting#189](https://github.com/n8n-io/n8n-hosting/pull/189), merged to the chart's `preview/worker-pools` branch. An official prerelease build can be published from that branch to the module's default chart registry via [n8n-io/n8n-hosting#191](https://github.com/n8n-io/n8n-hosting/pull/191)'s `Preview chart` GitHub Action, which is why `n8n_chart_version` is a required input of this example and the module fails the plan unless the pinned chart is a worker-pools preview build (a prerelease whose identifier contains `workerpools`) or is attested with `n8n_worker_pools_chart_verified`. See "Getting a chart that renders pools" below.
>
> Treat this example as non-production until all three are released.
>
> **Redis auth for pool scalers.** A pool's KEDA triggers reference the same `n8n-redis-auth` `TriggerAuthentication` the default worker's do whenever the module manages a Redis password Secret or a Memorystore instance with `redis_transit_encryption_enabled = true` (verified against the `1.11.0-preview.workerpools.1` chart's `queueMode.workerGroups[].keda.authenticationRef`), and carry `enableTLS` by the same rule, so the two trigger sets agree by construction. `tests/scripts/verify-worker-pools.sh` compares both after apply.
>
> **KEDA is required.** The chart renders a pool's `ScaledObject` only while release-wide KEDA scaling is on and otherwise runs the pool at 1 replica, so `n8n_worker_pools` fails validation when `n8n_worker_keda_enabled = false`.

## What it creates

- Everything [`small`](../small/) creates: VPC, GKE cluster, Cloud SQL, Memorystore, GCS, the controllers, and the n8n Helm release
- Three additional worker Deployments (`n8n-worker-heavy`, `n8n-worker-secteam`, `n8n-worker-itop`), each with its own KEDA `ScaledObject` of the same name watching that pool's own `jobs-<name>` queue. **Only with a chart that renders `queueMode.workerGroups`**; an older chart accepts the key and renders none of this, which is the failure [`verify-worker-pools.sh`](../../tests/scripts/verify-worker-pools.sh) exists to catch.
- `N8N_WORKER_POOLS_ENABLED` across mains, workers and webhook pods, emitted automatically because pools are declared

## The pool topology

Defined in [`main.tf`](./main.tf) as a local rather than a variable, since the topology is the point of the example rather than a knob (a local is also reachable from the example's tests, where a literal at the module call site would not be):

| Pool | Replicas | Concurrency | Sizing | Why |
|---|---|---|---|---|
| *(unlabelled)* | 1 to 10 | module default | module default | Serves the default `jobs` queue for every unpinned project |
| `heavy` | 1 to 4 | 5 | 1-2 vCPU, 2-4 GiB | Heavier executions, fewer jobs per worker. Same node pool as everything else; bigger requests, not different hardware |
| `secteam` | 1 to 3 | module default | module default | Isolation for one team's projects |
| `itop` | 0 to 3 | module default | module default | Scales to zero when idle |

A pool with no live workers is not an error. A job routed to it waits on the pool's queue and KEDA scales the pool up (0 to 1 in one polling interval, measured on terraform-aws-n8n's own worker-pools example), so `itop` costs nothing while idle. The catch is assignment: a project can only be pinned to a pool that currently has a registered worker, so a pool that starts life at 0 has to be raised to 1 once for the assignment. See step 4 of the end-to-end test.

Pool names are lowercase letters, digits and hyphens, 1 to 43 characters, starting and ending alphanumeric. The 43 comes from KEDA by way of the chart: the pool's ScaledObject is named `n8n-worker-<name>`, KEDA caps that at 54 characters because it doubles as a label value and as part of the generated HPA's name, and the chart fails the render past it. The chart's own schema allows 53, but that only holds for a shorter release name than the module's fixed `n8n`, so the module enforces the tighter figure and a name cannot pass plan and fail at apply. The module rejects anything else at plan time, because n8n itself only logs a warning for a bad name and then starts the worker on the default queue, which leaves a Ready pod quietly serving the wrong jobs. `default` is rejected too: it would mean a queue named `jobs-default`, which is not the real default queue.

## Prerequisites

- A Google Cloud project with the required APIs enabled (see the root README's Prerequisites section).
- An n8n Enterprise licence carrying `feat:workerPools`. For a multi-main deployment (the module's default) it also needs `feat:multipleMainInstances`; set `n8n_main_hpa_min_replicas = 1` to run single-main on a Business-tier licence.
- A chart that renders `queueMode.workerGroups`, reachable from both your workstation and the cluster: the official preview build `1.11.0-preview.workerpools.1` is already published to the module's default `oci://ghcr.io/n8n-io/n8n-helm-chart` (see the next section), or a registry you control otherwise.
- `helm` 3.8+ on your workstation, to confirm the pinned chart resolves before applying (and, on the private-mirror fallback, to package and push it yourself; add the `gcloud` CLI for that path).

## Getting a chart that renders pools

Skip this section, and pin your released chart directly with `n8n_worker_pools_chart_verified = true`, once you have confirmed your target chart renders `queueMode.workerGroups` -- today that means either a private mirror you have built and checked yourself, or an upstream release once one carries the feature.

Until then, the fastest path is the chart repo's own **official preview build**. [n8n-io/n8n-hosting#191](https://github.com/n8n-io/n8n-hosting/pull/191) registered a `Preview chart` GitHub Action on `main` that packages the `preview/worker-pools` branch (carrying [#189](https://github.com/n8n-io/n8n-hosting/pull/189)) and pushes a prerelease build to `oci://ghcr.io/n8n-io/n8n-helm-chart`, this module's own default `n8n_chart_repository`. Anyone with write access to n8n-io/n8n-hosting can dispatch it:

```bash
# From the GitHub UI: Actions -> Preview chart -> Run workflow, ref preview/worker-pools.
# Equivalent via the CLI:
gh workflow run preview-chart.yml --repo n8n-io/n8n-hosting --ref preview/worker-pools \
  -f build=1 -f repository=oci://ghcr.io/n8n-io/n8n-helm-chart
```

That publishes `n8n-1.11.0-preview.workerpools.1` (bump `build` for a later attempt; the workflow rejects re-pushing an existing version). Confirm it landed, then pin it:

```bash
helm show chart oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version 1.11.0-preview.workerpools.1 | head -5
```

```hcl
n8n_chart_version = "1.11.0-preview.workerpools.1"   # n8n_chart_repository stays at its default
n8n_image_tag      = "2.39.0"
```

**No write access to n8n-io/n8n-hosting?** Package the chart yourself from the feature branch and push it to a registry you control instead, e.g. Artifact Registry. The GKE node pool's Workload Identity service account needs `roles/artifactregistry.reader` on that repository, granted outside this module; the Helm provider on your workstation authenticates with the usual `helm registry login`.

```bash
GCP_PROJECT=my-gcp-project-id
GCP_REGION=us-east4
CHART_VERSION="1.11.0-preview.workerpools.1"   # base version of the branch's Chart.yaml, plus a prerelease suffix

# 1. Check out the branch (#189 is merged into it, not a standalone PR head anymore).
git clone https://github.com/n8n-io/n8n-hosting.git /tmp/n8n-hosting
cd /tmp/n8n-hosting
git checkout preview/worker-pools

# 2. Lint and render once locally, with this example's values shape, before pushing.
helm lint charts/n8n -f charts/n8n/ci/workerGroups-values.yaml
helm template n8n charts/n8n -f charts/n8n/ci/workerGroups-values.yaml \
  | grep -E '^kind: (Deployment|ScaledObject)$' | sort | uniq -c

# 3. Package with a prerelease version whose identifier names the feature.
#    Helm never picks a prerelease up by accident, and the module's
#    chart-version check takes a "workerpools" prerelease at your word.
helm package charts/n8n --version "$CHART_VERSION" --destination /tmp/chart-pkg

# 4. Create an Artifact Registry Docker repository (once) and push.
gcloud artifacts repositories create n8n-helm-chart \
  --repository-format=docker --location="$GCP_REGION" --project="$GCP_PROJECT" 2>/dev/null || true
gcloud auth print-access-token \
  | helm registry login -u oauth2accesstoken --password-stdin "$GCP_REGION-docker.pkg.dev"
helm push "/tmp/chart-pkg/n8n-$CHART_VERSION.tgz" \
  "oci://$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/n8n-helm-chart"

# 5. Confirm the module will find it.
helm show chart "oci://$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/n8n-helm-chart/n8n" --version "$CHART_VERSION" | head -5
```

Then in `terraform.tfvars`:

```hcl
n8n_chart_version    = "1.11.0-preview.workerpools.1"
n8n_chart_repository = "oci://us-east4-docker.pkg.dev/my-gcp-project-id/n8n-helm-chart"
n8n_image_tag        = "2.39.0"
```

The `helm registry login` access token is short-lived; if a later `terraform apply` fails with `unauthorized` on the chart pull, run step 4's login line again.

`CHART_VERSION` above carries a prerelease identifier that names the feature
(`workerpools`), which is what the module's guard keys on, so it is taken at
its word without any extra input. If you would rather package and distribute
this internally under a real numbered version or a generic prerelease
(dropping or changing the `-preview.workerpools.1` suffix in `CHART_VERSION`,
step 3's `--version`, and both `terraform.tfvars` snippets), add
`n8n_worker_pools_chart_verified = true` to `terraform.tfvars` alongside it:
that is the one thing this guard cannot infer from such a version string, so
it has to be an explicit attestation that you have already run steps 2 and 5
successfully against that exact chart.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_fqdn, project_id, cloud_dns_zone_name,
# n8n_license_key, n8n_chart_version and n8n_image_tag (n8n_chart_repository
# too, only if you're not using the module's default
# oci://ghcr.io/n8n-io/n8n-helm-chart).

terraform init
terraform plan    # fails unless n8n_chart_version is a worker-pools preview build (or attested); a "worker_pools_require_n8n_2_39" warning means the image pin is too old
terraform apply
```

## Verifying the pools

Run the scripted check first. It reads `worker_pool_names` and `n8n_kube_namespace` from this example's outputs and counts what the cluster actually has against them, which is the one check that catches a chart that ignored `queueMode.workerGroups`:

```bash
../../tests/scripts/verify-worker-pools.sh
```

It asserts, per pool: the `n8n-worker-<pool>` Deployment exists and carries the `n8n.io/worker-pool` label; the ScaledObject of the same name exists and targets that Deployment; the ScaledObject is `READY=True` and its triggers watch `bull:jobs-<pool>:wait` / `:active` with the same `enableTLS` metadata and the same `authenticationRef` (or none) the default worker's triggers carry; running pool pods have `N8N_WORKER_POOL_NAME` set; the main Deployment has `N8N_WORKER_POOLS_ENABLED=true`; and KEDA's external metric for the pool's queue resolves. It also fails if the cluster has pool Deployments the outputs do not list.

By hand, the same thing:

```bash
eval "$(terraform output -raw kubectl_config_command)"

# One Deployment and one ScaledObject per pool. The chart labels them
# component=worker-group (not worker: the default worker's selector is
# immutable and must not match pool pods) and n8n.io/worker-pool=<name>.
kubectl -n n8n get deploy,scaledobject -l app.kubernetes.io/component=worker-group

# The pool name reached the pods.
kubectl -n n8n get pods -l n8n.io/worker-pool=heavy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[?(@.name=="n8n-worker")].env[?(@.name=="N8N_WORKER_POOL_NAME")].value}{"\n"}{end}'
```

The pools also appear in the n8n UI under **Settings, Workers**, which shows each worker's pool and queue, and in a project's **Worker Pools** settings once a worker for that pool is running.

### An end-to-end execution on a pool

The scripted check proves the topology exists; this proves routing. Nothing in the module can do it for you because assigning a project to a pool is a UI (or internal API) action, not a Terraform one.

1. In n8n, open a project, then **Settings, Worker Pools**, and assign it to `heavy`.
2. Create a trivial workflow in that project (Manual Trigger, then a Wait node of ~20 seconds so it stays visible) and run it.
3. While it runs, the execution should be on a `heavy` pod and nowhere else:

   ```bash
   # The heavy pool picked it up: one of these pods logs the execution id.
   kubectl -n n8n logs -l n8n.io/worker-pool=heavy -c n8n-worker --since=2m | grep -i 'execution'

   # The default workers did not.
   kubectl -n n8n logs -l app.kubernetes.io/component=worker -c n8n-worker --since=2m | grep -i 'execution' || echo "default workers idle, as expected"

   # The queue depth KEDA scales heavy on (0 once the worker has taken the job).
   kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/n8n/s0-redis-bull-jobs-heavy-wait?labelSelector=scaledobject.keda.sh/name=n8n-worker-heavy"
   ```

4. Scale-from-zero, using `itop`. The job waits on `jobs-itop` (the default queue's counter does not move), KEDA scales `n8n-worker-itop` from 0 to 1 within one 15-second polling interval, the new pod runs the execution, and the pool returns to 0 once the queue is empty. There is no fallback to the default queue. Watch it with:

   ```bash
   kubectl -n n8n get deploy n8n-worker-itop -w &
   kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/n8n/s0-redis-bull-jobs-itop-wait?labelSelector=scaledobject.keda.sh/name=n8n-worker-itop"
   ```

   **Bootstrap caveat.** A project can only be assigned to a pool that currently has a registered worker: the Worker Pools dropdown is built from the live instance registry, so a pool parked at 0 is not offered. On a fresh deployment `itop` is therefore invisible until something scales it up, and nothing will, because nothing can be routed to it. To pin a project to `itop` the first time, raise the floor briefly and drop it again once the assignment is saved; the assignment is stored per project and survives the scale-down:

   ```bash
   kubectl -n n8n patch scaledobject n8n-worker-itop --type merge -p '{"spec":{"minReplicaCount":1}}'
   # assign the project in the UI, then
   kubectl -n n8n patch scaledobject n8n-worker-itop --type merge -p '{"spec":{"minReplicaCount":0}}'
   ```

   Or set `min_replicas = 1` in `main.tf` for the first apply and lower it afterwards. Terraform will reconcile the patched ScaledObject back to the declared value on the next apply either way.

5. Negative control: unassign the project from `heavy`, run again, and confirm the execution now lands on a default worker.

### Checking a pool's autoscaler

A pool that cannot reach Redis does not crash. It sits at its `min_replicas` and the queue simply never drains, so it is worth knowing which signal actually tells you.

```bash
# READY=True is the one to trust. A scaler that cannot reach Redis reads False.
kubectl -n n8n get scaledobject

# Queue depth as KEDA sees it, per pool.
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/n8n/\
s0-redis-bull-jobs-heavy-wait?labelSelector=scaledobject.keda.sh/name=n8n-worker-heavy"
```

Do not read `kubectl get hpa` for this. Its TARGETS column shows `<unknown>` for a KEDA-backed worker HPA whether the scaler is healthy or broken, so it gives a false alarm either way. When something is genuinely wrong, `kubectl -n keda logs -l app=keda-operator` says so in as many words, usually `connection to redis failed: i/o timeout`.

## Post-deployment

See [../../docs/post-deployment.md](../../docs/post-deployment.md) for activating your n8n Enterprise license.

## Teardown

```bash
terraform destroy
```

## Production considerations

This example is a reference deployment optimized for clean `apply` / `destroy` cycles during evaluation. Review the root README's own "Production considerations" guidance (backup retention, deletion protection, force-destroy) before promoting it, on top of the alpha-feature caveats above.

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs .` to refresh it. -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.23 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 6.23 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.23 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloud_dns_zone_name"></a> [cloud\_dns\_zone\_name](#input\_cloud\_dns\_zone\_name) | Google Cloud DNS managed-zone name for n8n\_fqdn. Empty means you manage the A-record yourself against the static\_ip output. | `string` | `""` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module creates. | `string` | `"dev"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_force_destroy"></a> [gcs\_force\_destroy](#input\_gcs\_force\_destroy) | Allow terraform destroy to delete the (non-empty) GCS bucket. | `bool` | `false` | no |
| <a name="input_gcs_location"></a> [gcs\_location](#input\_gcs\_location) | GCS bucket location for binary storage. Keep it near gcp\_region (e.g. US for a us-* region, EU for europe-*). | `string` | `"US"` | no |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_gke_node_max_per_zone"></a> [gke\_node\_max\_per\_zone](#input\_gke\_node\_max\_per\_zone) | Autoscaling maximum GKE nodes per zone, passed straight through to the module's gke\_node\_max\_per\_zone. The three worker pools this example declares are additional autoscalers on the same node pool, not a redistribution of the ceilings already there, so this defaults higher than the module's own default of 4. See main.tf. | `number` | `6` | no |
| <a name="input_manage_sa_key_org_policy"></a> [manage\_sa\_key\_org\_policy](#input\_manage\_sa\_key\_org\_policy) | Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise. | `bool` | `false` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Additional hostnames to give the full main/webhook route set alongside n8n\_fqdn. Passed straight through to the module's n8n\_additional\_domains. Default empty (no aliases). | `list(string)` | `[]` | no |
| <a name="input_n8n_chart_repository"></a> [n8n\_chart\_repository](#input\_n8n\_chart\_repository) | Helm chart repository the module pulls the n8n chart from, passed to the module's n8n\_chart\_repository. The default is the module's own default, the public upstream registry, which is right both once a released chart renders pools and while using an official prerelease build published there. Only override this to point at a registry you control, e.g. Artifact Registry, if you packaged and pushed a preview build yourself. | `string` | `"oci://ghcr.io/n8n-io/n8n-helm-chart"` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | n8n Helm chart version to deploy, passed to the module's n8n\_chart\_version. Required by this example because the module default predates queueMode.workerGroups and would render no pools. Pin a worker-pools preview build (a prerelease whose identifier contains "workerpools", e.g. 1.11.0-preview.workerpools.1, published to n8n\_chart\_repository's default via n8n-io/n8n-hosting's Preview chart GitHub Action, or to a registry you control) until a numbered release carries the feature. See README.md, "Getting a chart that renders pools". | `string` | n/a | yes |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. | `string` | n/a | yes |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n image tag to deploy, passed straight through to the module's n8n\_image\_tag. Required by this example (no default): worker pools need n8n >= 2.39.0; the chart's own default tag (its appVersion) may sit below that, so pin explicitly. See README.md. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Must carry feat:workerPools (see README.md); multi-main additionally needs feat:multipleMainInstances. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main, needs feat:multipleMainInstances on top of feat:workerPools). Set to 1 to run single-main queue mode instead. | `number` | `null` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Maximum replicas for the chart's own unlabelled worker deployment, passed straight through to the module's n8n\_worker\_keda\_max\_replicas. | `number` | `10` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Minimum replicas for the chart's own unlabelled worker deployment (the default `jobs` queue), passed straight through to the module's n8n\_worker\_keda\_min\_replicas. | `number` | `1` | no |
| <a name="input_n8n_worker_pools_chart_verified"></a> [n8n\_worker\_pools\_chart\_verified](#input\_n8n\_worker\_pools\_chart\_verified) | Attests that n8n\_chart\_version renders queueMode.workerGroups, passed straight through to the module's n8n\_worker\_pools\_chart\_verified. Only needed for a chart version that is not a worker-pools preview build (a numbered release or generic prerelease on a private mirror you have already verified); a prerelease whose identifier contains "workerpools" is taken at your word from the version string itself. Leave false (the default) while pinning the official preview build. | `bool` | `false` | no |
| <a name="input_postgres_backup_retained_backups"></a> [postgres\_backup\_retained\_backups](#input\_postgres\_backup\_retained\_backups) | Number of automated backups Cloud SQL retains. Null (the default) preserves the provider's own default retention. Passed straight through to the module's postgres\_backup\_retained\_backups. | `number` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_postgres_transaction_log_retention_days"></a> [postgres\_transaction\_log\_retention\_days](#input\_postgres\_transaction\_log\_retention\_days) | Days of transaction logs Cloud SQL retains for point-in-time recovery. Null (the default) preserves the provider's own default. Passed straight through to the module's postgres\_transaction\_log\_retention\_days. | `number` | `null` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | gcloud command that writes kubeconfig credentials for the GKE cluster. |
| <a name="output_n8n_database_password"></a> [n8n\_database\_password](#output\_n8n\_database\_password) | Cloud SQL PostgreSQL password. Back this up in a password manager. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key. Back this up in a password manager. |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | Kubernetes namespace n8n is deployed into. Read by tests/scripts/verify-worker-pools.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | HTTPS URL of the n8n editor. |
| <a name="output_redis_host"></a> [redis\_host](#output\_redis\_host) | Effective Redis host (module-managed Memorystore or external). |
| <a name="output_redis_tls_enabled"></a> [redis\_tls\_enabled](#output\_redis\_tls\_enabled) | Whether the effective Redis connection uses TLS. |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | LB static IP. Point n8n\_fqdn at this if you are not letting the module manage Cloud DNS. |
| <a name="output_worker_pool_names"></a> [worker\_pool\_names](#output\_worker\_pool\_names) | Names of the worker pools this example declares, in declaration order. Read by tests/scripts/verify-worker-pools.sh, which counts the rendered pool Deployments and ScaledObjects against this list: the chart-predates-pools failure leaves this list non-empty and the cluster with nothing behind it, and only a live count can see that. |
<!-- END_TF_DOCS -->
