# Sandbox profile

[`examples/small/`](../examples/small/) is already the module's cheapest
end-to-end reference, but it still runs the module's full default replica
ceilings: a main HPA that can scale to 20, a worker that can scale to 10, and
a webhook processor that can scale to 50. This document describes a cheaper
single-main sandbox profile you can layer on top of `small` (or your own root
module) today, using only inputs the module already exposes. There is no
separate `sandbox` example.

## What you can set today

Every input below is a plain override on the root module:

| Input | Sandbox value | Why |
|---|---|---|
| `n8n_main_hpa_min_replicas` | `1` | Single-main mode. Does not require `feat:multipleMainInstances`. |
| `n8n_main_hpa_max_replicas` | `1` | Not required: the effective ceiling already clamps to 1 in single-main mode (`locals.tf`'s `n8n_effective_main_hpa_max_replicas`), so the capacity diagnostics model one main replica regardless of this value. Setting it to `1` here just keeps the input honest about what single-main mode actually runs. |
| `n8n_webhook_hpa_min_replicas` / `n8n_webhook_hpa_max_replicas` | `1` | One webhook processor. |
| `n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas` | `1` | One worker. |
| `gke_node_min_per_zone` | `1` | GKE's autoscaling floor per zone (a regional node pool spans 3 zones, so 3 nodes total at this floor). |
| `gke_node_max_per_zone` | `2` | Leaves headroom for a rolling node upgrade without paying for a second pool's steady-state node. |
| `gke_node_type` | A smaller machine type than the `e2-standard-4` default, e.g. `e2-standard-2` | Unlike some other clouds' AKS-style dual node pools, this module manages a single `google_container_node_pool` (`gke.tf`), so there is no second pool to also resize. |
| `postgres_machine_type` | `db-g1-small` (already the module's own default; see the budget section below) | Cheapest Cloud SQL tier, shared-core. |
| `db_postgresdb_pool_size` | `3` or lower | See the budget section below. |
| `postgres_connection_budget_check_enabled` | `true` | Recommended here: this profile's numbers fit the budget, so the advisory check (off by default) stays useful as a regression guard. See the budget section below. |

## PostgreSQL connection budget

Cloud SQL for PostgreSQL derives `max_connections` once, at instance
provisioning, from the selected machine type's memory, and does **not**
recalculate it if you change `postgres_machine_type` later; the old ceiling
sticks until the instance is re-created ([Cloud SQL database
flags](https://cloud.google.com/sql/docs/postgres/flags), the
`max_connections` row: "The default value depends on the amount of memory
of the largest instance in the chain of primaries"). Each main, worker, and
webhook-processor pod can lazily open up to `db_postgresdb_pool_size`
connections against the same instance (`db_postgresdb_pool_size`'s
description in `variables.tf`), so the aggregate ceiling is:

```
db_postgresdb_pool_size * (main replicas + worker replicas + webhook replicas + any n8n_worker_pools ceilings)
```

`db-g1-small` (this profile's tier, and the module's own default) is
Google's "small (~1.7 GB)" bucket: **50** default user connections. At the
single-main sandbox sizes above (1 main + 1 worker + 1 webhook = 3 pods),
`db_postgresdb_pool_size = 10` (the module default) would request up to 30
connections, under the 50-connection budget but with little headroom to
also add a worker pool or raise any replica ceiling. `db_postgresdb_pool_size
= 3` leaves more room (up to 9 connections at these replica counts).

The root module's `check.postgres_pool_size_fits_known_max_connections`
(`checks.tf`) can warn at plan time whenever this arithmetic exceeds the
known limit for `postgres_machine_type`, derived from Google's own published
memory-to-`max_connections` table. It is opt-in
(`postgres_connection_budget_check_enabled`, default `false`): the module's
own *default* autoscaler ceilings (main 20, worker 10, webhook 50) already
request up to 800 connections at the default `db_postgresdb_pool_size = 10`,
over db-g1-small's 50-connection budget, so leaving the check on by default
would warn on every unmodified deployment. **This profile's numbers above
are chosen to stay under db-g1-small's 50-connection budget**, so it is a
good place to set `postgres_connection_budget_check_enabled = true`: once
you have settled on replica ceilings and a `postgres_machine_type`, turning
the check on catches a later regression (raising a ceiling, lowering the
machine type, or raising `db_postgresdb_pool_size`) before it causes
connection exhaustion under load. After applying, confirm the instance's
actual live setting with:

```sql
SELECT current_setting('max_connections');
```

## Redis and storage

This profile does not need to change `redis_tier` or `redis_memory_size_gb`
from the module's own defaults (`BASIC` / `1`) -- Memorystore is already
sized independently of PostgreSQL and GKE.
