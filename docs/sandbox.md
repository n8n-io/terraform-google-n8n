# Sandbox profile

[`examples/small/`](../examples/small/) is already the module's cheapest
end-to-end reference, but it still runs the module's full default replica
ceilings: a main HPA that can scale to 20, a worker that can scale to 10, and
a webhook processor that can scale to 50. This document describes a cheaper
single-main sandbox profile built only from inputs the module already
exposes. There is no separate `sandbox` example.

## What you can set today

Set the inputs below as arguments in your `module "n8n"` block:

| Input | Sandbox value | Why |
|---|---|---|
| `n8n_main_hpa_min_replicas` | `1` | Single-main mode. Does not require `feat:multipleMainInstances`. |
| `n8n_main_hpa_max_replicas` | `1` | Not required: the effective ceiling already clamps to 1 in single-main mode (`locals.tf`'s `n8n_effective_main_hpa_max_replicas`), so the capacity diagnostics model one main replica regardless of this value. Setting it to `1` keeps the input consistent with what single-main mode runs. |
| `n8n_webhook_hpa_min_replicas` / `n8n_webhook_hpa_max_replicas` | `1` | One webhook processor. |
| `n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas` | `1` | One worker. |
| `gke_node_min_per_zone` | `1` | GKE's autoscaling floor per zone (a regional node pool spans 3 zones, so 3 nodes total at this floor). |
| `gke_node_max_per_zone` | `2` | Leaves headroom for a rolling node upgrade. |
| `gke_node_type` | A smaller machine type than the `e2-standard-4` default, e.g. `e2-standard-2` | The module manages one node pool (`google_container_node_pool` in `gke.tf`), so this is the only machine type to change. |
| `postgres_machine_type` | `db-g1-small` (already the module's own default; see the budget section below) | Low-cost shared-core tier. |
| `db_postgresdb_pool_size` | `3` or lower | See the budget section below. |
| `postgres_connection_budget_check_enabled` | `true` | Recommended here: this profile's numbers fit the budget, so the advisory check (off by default) is useful as a regression guard. See the budget section below. |

For example:

```hcl
module "n8n" {
  source = "../.." # or the registry source

  # ... your existing required inputs ...

  n8n_main_hpa_min_replicas    = 1
  n8n_main_hpa_max_replicas    = 1
  n8n_webhook_hpa_min_replicas = 1
  n8n_webhook_hpa_max_replicas = 1
  n8n_worker_keda_min_replicas = 1
  n8n_worker_keda_max_replicas = 1

  gke_node_min_per_zone = 1
  gke_node_max_per_zone = 2
  gke_node_type         = "e2-standard-2"

  postgres_machine_type                    = "db-g1-small"
  db_postgresdb_pool_size                  = 3
  postgres_connection_budget_check_enabled = true
}
```

If you start from `examples/small/`, edit the `module "n8n"` block in its
`main.tf`: replace its existing `n8n_main_hpa_min_replicas` argument and add
the others. Setting them only in `terraform.tfvars` does not work: that
example passes `n8n_main_hpa_min_replicas` through to the module, but none of
the other inputs above.

## PostgreSQL connection budget

Cloud SQL for PostgreSQL automatically manages `max_connections` from the
instance's current memory, and recalculates it whenever you change
`postgres_machine_type`. The instance restarts, and read replicas may restart
too. See [Cloud SQL instance
settings](https://cloud.google.com/sql/docs/postgres/instance-settings) and
the [Cloud SQL database
flags](https://cloud.google.com/sql/docs/postgres/flags) page's
`max_connections` row: "The default value depends on the amount of memory
of the largest instance in the chain of primaries". Each main, worker, and
webhook-processor pod can lazily open up to `db_postgresdb_pool_size`
connections against the same instance (`db_postgresdb_pool_size`'s
description in `variables.tf`), so the aggregate ceiling is:

```
db_postgresdb_pool_size * (main replicas + worker replicas + webhook replicas + any n8n_worker_pools ceilings)
```

`db-g1-small` (this profile's tier, and the module's own default) is
Google's "small (~1.7 GB)" bucket: a default `max_connections` of **50**. At
the single-main sandbox sizes above (1 main + 1 worker + 1 webhook = 3 pods),
`db_postgresdb_pool_size = 10` (the module default) would request up to 30
connections, under the limit but with little headroom to also add a worker
pool or raise any replica ceiling. `db_postgresdb_pool_size = 3` leaves more
room (up to 9 connections at these replica counts).

The root module's `check.postgres_pool_size_fits_known_max_connections`
(`checks.tf`) can warn at plan time whenever this arithmetic exceeds the
default `max_connections` for `postgres_machine_type`, derived from Google's
published memory-to-`max_connections` table. The check only runs when
`create_postgres_instance = true`, and only recognizes `db-f1-micro`,
`db-g1-small`, `db-custom-<vcpus>-<memory_mb>`, and
`db-perf-optimized-N-<vcpus>` shapes. It stays silent for other shapes (for
example `db-perf-optimized-C4-*`, `db-c4a-highmem-*`, predefined series)
rather than guess at their memory.

The check is opt-in (`postgres_connection_budget_check_enabled`, default
`false`). The module's own *default* autoscaler ceilings (main 20, worker 10,
webhook 50) already request up to 800 connections at the default
`db_postgresdb_pool_size = 10`, far over `db-g1-small`'s 50, so leaving the
check on by default would warn on every unmodified deployment. **This
profile's numbers are chosen to stay under `db-g1-small`'s 50**, so it is a
good place to turn the check on. Once you have settled on replica ceilings
and a `postgres_machine_type`, the check catches a later regression (raising
a ceiling, lowering the machine type, or raising `db_postgresdb_pool_size`)
before it causes connection exhaustion under load.

### What the check does not see

The check is an optimistic threshold. A warning means the ceilings exceed the
default limit. Silence does not prove they fit:

- It compares against the raw `max_connections` default, not the connections
  n8n can use. PostgreSQL reserves `superuser_reserved_connections` out of
  `max_connections`, the module's database user is not a real superuser, and
  every other client of the instance shares the rest.
- It counts configured steady-state ceilings. Extra pods that a rolling
  update adds are not counted, so leave headroom.
- While `n8n_worker_keda_pause = true` and `n8n_worker_keda_enabled = true`,
  it counts `n8n_worker_keda_paused_replica_count` when that is larger than
  the worker maximum. If you clear the count while still paused, KEDA keeps
  the workers at their current number, which can still be above the maximum.
  The check then counts only the maximum.
- If you turn off a module-managed autoscaler (`n8n_main_hpa_enabled`,
  `n8n_worker_keda_enabled`, or `n8n_webhook_hpa_enabled` set to `false`), it
  counts that role's fixed replica count. An autoscaler you manage yourself
  can scale past it.
- The module has no input for the `max_connections` database flag, and it
  manages `database_flags` itself, so a flag set outside Terraform is removed
  on the next apply.

After applying, confirm the instance's live setting with:

```sql
SELECT current_setting('max_connections');
```

## Redis and storage

This profile does not need to change `redis_tier` or `redis_memory_size_gb`
from the module's own defaults (`BASIC` / `1`). Memorystore is sized
independently of PostgreSQL and GKE.
