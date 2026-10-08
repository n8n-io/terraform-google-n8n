# PostgreSQL TLS and server-certificate verification

Both the module-managed Cloud SQL path and the external PostgreSQL path connect over TLS once `db_postgresdb_ssl_enabled = true`, but that setting alone only encrypts the connection: it does not check that the certificate the server presents actually belongs to the host n8n dialed. `db_postgresdb_ssl_reject_unauthorized` closes that gap, with one hard limitation on the module-managed Cloud SQL path that this document explains so you do not enable a setting that fails at runtime.

## n8n's verification model has no partial mode

n8n's PostgreSQL driver (`pg`/node-postgres) exposes a single `rejectUnauthorized` flag, not libpq's separate `verify-ca` (validate the certificate chain, skip the hostname check) and `verify-full` (validate the chain and the hostname) modes. Setting `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=true` always performs both the chain check and a hostname/IP check against the certificate's Subject Alternative Names (SANs), via Node's TLS module. There is no environment variable this module (or n8n) exposes to request chain-only verification while skipping the hostname check.

This matters because of how Cloud SQL issues server certificates.

## Why this blocks the module-managed Cloud SQL path

This module always connects to its module-managed Cloud SQL instance over the instance's **private IP** (Private Service Access, never a public IP or a DNS name).

Google [documents Cloud SQL hostname verification by DNS name](https://docs.cloud.google.com/sql/docs/postgres/configure-ssl-instance), not by IP address:

- With the per-instance CA, Google states that verifying the CA also verifies the server identity, because each instance has its own CA. That is a chain-only check, which n8n cannot perform (see above). Google documents DNS-name verification with the per-instance CA only for Private Service Connect instances.
- With the shared CA server CA mode (`GOOGLE_MANAGED_CAS_CA`), the server certificate carries the instance DNS name in its SAN. For a Private Service Access instance that name has the form `INSTANCE_UID.PROJECT_DNS_LABEL.REGION_NAME.sql-psa.goog.`, and you must resolve it through a private DNS zone in the VPC network.
- With a customer-managed CA, you can add custom DNS names to the SAN.

Google's documentation does not describe hostname verification of a Cloud SQL server certificate against an IP address. This module does not set `settings.ip_configuration.server_ca_mode`, does not create a DNS record for the instance DNS name, and passes the private IP as the database host. Node's hostname check therefore has no documented name to match, and enabling `db_postgresdb_ssl_reject_unauthorized` against the module-managed instance is expected to fail the TLS handshake on every connection. Rather than ship a `verify-full`-style toggle that breaks a working deployment, `db_postgresdb_ssl_reject_unauthorized`'s own `validation` block rejects the combination at plan time:

```text
db_postgresdb_ssl_reject_unauthorized requires db_postgresdb_ssl_enabled = true (an unencrypted connection has no certificate to verify) and create_postgres_instance = false (the module connects to its own Cloud SQL instance by private IP, and Google documents Cloud SQL hostname verification only by DNS name, so n8n's hostname check is expected to fail there; see docs/postgresql-tls.md).
```

If your organization's TLS policy requires certificate verification against the module-managed Cloud SQL instance, this module does not currently support it; verification only works on the external PostgreSQL path (below). One way to support it on the managed path would be for this module to set the shared CA server CA mode, create a private DNS record for the instance DNS name, and use that name as the connection host. A customer-managed CA with a custom DNS name is another option Google documents. The module does none of these today.

## Using it on the external PostgreSQL path

`n8n_database_host` on the external path (`create_postgres_instance = false`) is whatever hostname you choose to supply, so it can be a real DNS name that matches the external server's own certificate. On that path, `db_postgresdb_ssl_reject_unauthorized = true` performs a genuine, working chain-plus-hostname check:

```hcl
create_postgres_instance              = false
n8n_database_host                     = "pg.internal.example.com"
db_postgresdb_ssl_enabled             = true
db_postgresdb_ssl_reject_unauthorized = true
db_postgresdb_ssl_ca_pem              = file("${path.module}/postgres-server-ca.pem")
```

`db_postgresdb_ssl_ca_pem` is the PEM-encoded CA bundle that issued the external server's certificate. The input has the same name as in terraform-aws-n8n. The module trims surrounding whitespace and passes the bundle to the n8n Helm chart's `database.ssl.ca` value. The chart renders it into its own ConfigMap as `DB_POSTGRESDB_SSL_CA`, which the main, worker, and webhook-processor pods read, and n8n passes that value to the TLS connection as PEM content. This is the same design as terraform-azurerm-n8n, and the design terraform-aws-n8n plans to move to ([terraform-aws-n8n#178](https://github.com/n8n-io/terraform-aws-n8n/issues/178)).

Because the CA is part of the Helm release:

- Changing the CA rolls the pods through the chart's own `checksum/config` pod annotation.
- A failed upgrade's atomic rollback (`helm_release.n8n` sets `atomic = true`) restores the previous CA together with the previous pod specification, as long as the rollback itself succeeds (see [When verification or a CA change fails](#when-verification-or-a-ca-change-fails)).
- Removing the CA removes it in the same Helm upgrade. There is no separate Kubernetes object for Terraform to delete first.

A CA certificate is public, so the input is not marked sensitive. It is stored in Terraform state and in the Helm release. You can commit the PEM file next to your Terraform configuration and pass it with `file()`. The module checks only that the value has PEM certificate framing (`-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----`); it does not parse the certificate. A bundle with more than one certificate is accepted.

If you set `db_postgresdb_ssl_ca_pem` but leave `db_postgresdb_ssl_reject_unauthorized = false`, the module does not pass the CA to the chart, and the `postgres_ssl_ca_ignored_without_verification` check warns at plan time. You can stage the CA this way before you turn on verification.

### Without a CA bundle

Leaving `db_postgresdb_ssl_ca_pem` null while `db_postgresdb_ssl_reject_unauthorized = true` is valid: verification then falls back to the pod image's bundled trust store, which succeeds only if the external server's certificate chains to a publicly trusted root CA already in that image.

In this mode n8n passes `ssl: true` to its PostgreSQL driver instead of an explicit `rejectUnauthorized` option, so the certificate check follows Node's process-wide default. If `n8n_extra_env`, `n8n_worker_extra_env`, or an `n8n_worker_pools` entry's `extra_env` sets `NODE_TLS_REJECT_UNAUTHORIZED=0`, Node skips the check on the affected pods. The `postgres_ssl_verification_disabled_by_node_tls_env` check warns about this at plan time. When you supply a CA bundle, n8n passes an explicit `rejectUnauthorized`, and `NODE_TLS_REJECT_UNAUTHORIZED` does not affect the database connection.

### Rotating the CA bundle

A CA change is a normal Helm values change, so each `terraform apply` below rolls the n8n pods. Rotation takes two applies, with the server certificate rotation in between:

1. Set `db_postgresdb_ssl_ca_pem` to a bundle with both the old and the new CA certificate, and apply. Wait until every n8n pod has been replaced and connects to the database before you continue.
2. Rotate the database server certificate to one issued by the new CA.
3. Set `db_postgresdb_ssl_ca_pem` to a bundle with only the new CA certificate, and apply.

Each rollout follows the Deployments' own strategies. A multi-main deployment replaces its main and webhook-processor pods gradually. A single-main deployment uses the `Recreate` strategy for its main Deployment, so the only main pod stops before the new one starts. Plan a short maintenance window for that case.

### When verification or a CA change fails

If the CA bundle does not cover the certificate chain the server presents, or `n8n_database_host` does not match a name in the server certificate, the new pods cannot connect to the database. Test a new bundle or host in a non-production environment first. What can happen on a failed rollout:

- The apply fails slowly. New pods crash-loop, and the Helm upgrade fails only when it reaches `n8n_helm_timeout` (600 seconds by default). `atomic = true` then rolls the release back to the previous values, including the previous CA. If the rollback succeeds, pods that Kubernetes creates afterwards use the previous CA again without another apply. The rollback itself can also fail, and the previous CA only helps if it still matches the server's current certificate (for example, not after the server has moved to a new CA). Keep a bundle that matches the server's current certificate, and set `db_postgresdb_ssl_ca_pem` back to a working bundle before the next apply.
- During the failing upgrade, the chart's shared ConfigMap already holds the new CA. Pods that are already running keep the CA they started with, but any pod that starts during that time, including an old-revision pod that restarts or a new pod from a scale-up, reads the new CA and can fail too.
- On a multi-main deployment, main and webhook-processor pods usually keep serving, because their HTTP readiness probes keep failing new pods out of rotation. This is not guaranteed, for the reason above.
- Workers can stop processing the queue until the rollback finishes. The pinned chart's worker readiness probe only checks that the `n8n worker` process exists (`pgrep`), so a new worker that cannot reach the database can still count as ready, and the rollout can remove a healthy old worker. Queued executions wait in Redis. This needs a chart change ([n8n-io/n8n-hosting#225](https://github.com/n8n-io/n8n-hosting/issues/225)) and affects all three n8n Terraform modules.
- On a single-main deployment, the `Recreate` strategy stops the only main pod before the new one starts, so the editor, REST API, and webhooks handled by main are unavailable until a working main pod is Ready.

The same applies the first time you turn on `db_postgresdb_ssl_reject_unauthorized`: there is no fallback to an unverified connection once the setting is live.

## Server-side enforcement: `postgres_ssl_mode`

Independent of whether n8n's client verifies anything, `postgres_ssl_mode` (`variables_gcp.tf`) controls whether the module-managed Cloud SQL instance itself accepts unencrypted connections at all (`google_sql_database_instance.ip_configuration.ssl_mode`):

- `ALLOW_UNENCRYPTED_AND_ENCRYPTED` (the default) accepts both, matching n8n's own default `DB_POSTGRESDB_SSL_ENABLED=false` client behavior.
- `ENCRYPTED_ONLY` rejects plaintext connections at the server. This requires `db_postgresdb_ssl_enabled = true` (enforced by `postgres_ssl_mode`'s own `validation` block); otherwise every n8n pod's connection attempt is refused and n8n never reaches the database.

`ENCRYPTED_ONLY` is unaffected by the hostname-verification limitation above: it only forces encryption, never certificate identity, so it is safe to combine with the module-managed Cloud SQL path.

### Turning on `ENCRYPTED_ONLY` for a running deployment

Terraform updates the Cloud SQL instance before it upgrades the n8n Helm release, because `helm_release.n8n` depends on `google_sql_database_instance.n8n`. If one apply sets both `db_postgresdb_ssl_enabled = true` and `postgres_ssl_mode = "ENCRYPTED_ONLY"`, the old n8n pods still connect in plaintext while the new pods roll out, and Cloud SQL refuses their new connections. If the Helm upgrade then fails and rolls back, the restored pods connect in plaintext against a server that only accepts encrypted connections. Use two applies instead:

1. Set `db_postgresdb_ssl_enabled = true`, apply, and wait until every n8n pod has been replaced.
2. Set `postgres_ssl_mode = "ENCRYPTED_ONLY"` and apply.

The second change does not restart the Cloud SQL instance, and it applies only to new connections. Unencrypted connections that are already open stay open until they close or you restart the instance, as described in [Google's documentation](https://docs.cloud.google.com/sql/docs/postgres/configure-ssl-instance). After step 1, n8n's own connections are already encrypted, so this matters only for other clients of the same instance.

To go back, reverse the order: set `postgres_ssl_mode = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"` before, or in the same apply as, `db_postgresdb_ssl_enabled = false`. Terraform applies the Cloud SQL change first, so the server accepts plaintext again before any pod switches to it.

## Summary table

| Variable | Scope | What it changes |
| --- | --- | --- |
| `db_postgresdb_ssl_enabled` | Both paths | Whether n8n encrypts the connection at all (`DB_POSTGRESDB_SSL_ENABLED`) |
| `db_postgresdb_ssl_reject_unauthorized` | External path only | Whether n8n validates the server's certificate chain *and* hostname (`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED`); rejected when `create_postgres_instance = true` |
| `db_postgresdb_ssl_ca_pem` | External path only | CA bundle n8n trusts for that verification, delivered through the chart's `database.ssl.ca`; ignored, with a plan-time warning, on the managed path or while `db_postgresdb_ssl_reject_unauthorized = false` |
| `postgres_ssl_mode` | Managed path only | Whether the Cloud SQL instance itself accepts plaintext connections at all |
