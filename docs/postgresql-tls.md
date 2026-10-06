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
db_postgresdb_ssl_ca_secret_ref = {
  name = "postgres-server-ca"
  key  = "ca.crt" # default; omit if your Secret already uses this key
}
```

`db_postgresdb_ssl_ca_secret_ref` references an existing Kubernetes Secret (in the n8n namespace) holding the PEM-encoded CA bundle that issued the external server's certificate. The module never reads the Secret's value: it only mounts the named key read-only at `/etc/n8n-certs/postgres-ssl-ca.crt` on every n8n role (main, worker, webhook processor) and points `DB_POSTGRESDB_SSL_CA_FILE` at that path. A missing Secret or key fails at pod-start time, not at plan time. While the module mounts this CA, `n8n_extra_volumes` cannot use the volume name `postgres-ssl-ca`.

If you set `db_postgresdb_ssl_ca_secret_ref` but leave `db_postgresdb_ssl_reject_unauthorized = false`, the module does not mount the Secret, and the `postgres_ssl_ca_ignored_without_verification` check warns at plan time.

### Without a CA bundle

Leaving `db_postgresdb_ssl_ca_secret_ref` null while `db_postgresdb_ssl_reject_unauthorized = true` is valid: verification then falls back to the pod image's bundled trust store, which succeeds only if the external server's certificate chains to a publicly trusted root CA already in that image.

In this mode n8n passes `ssl: true` to its PostgreSQL driver instead of an explicit `rejectUnauthorized` option, so the certificate check follows Node's process-wide default. If `n8n_extra_env`, `n8n_worker_extra_env`, or an `n8n_worker_pools` entry's `extra_env` sets `NODE_TLS_REJECT_UNAUTHORIZED=0`, Node skips the check on the affected pods. The `postgres_ssl_verification_disabled_by_node_tls_env` check warns about this at plan time. When you supply a CA bundle, n8n passes an explicit `rejectUnauthorized`, and `NODE_TLS_REJECT_UNAUTHORIZED` does not affect the database connection.

### Rotating the CA bundle

The module mounts the CA file with `subPath`, and Kubernetes does not update `subPath` mounts when the Secret changes. n8n also reads `DB_POSTGRESDB_SSL_CA_FILE` only at startup. Changing the Secret's contents therefore produces no Terraform diff and no pod restart. To rotate the CA without breaking database connections:

1. Add the new CA certificate to the Secret's bundle next to the old one.
2. Restart every n8n Deployment (main, worker, webhook processor, and any worker pool), for example with `kubectl -n <namespace> rollout restart deployment/<name>` for each one, and wait for the rollouts to finish.
3. Rotate the database server certificate to one issued by the new CA.
4. Remove the old CA certificate from the Secret's bundle and restart the n8n Deployments again.

The restarts follow each Deployment's own rollout strategy. A multi-main deployment replaces its pods gradually. A single-main deployment uses the `Recreate` strategy, so restarting its main Deployment stops the only main pod before the new one starts. Plan a short maintenance window for that case.

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
| `db_postgresdb_ssl_ca_secret_ref` | External path only | CA bundle n8n trusts for that verification; ignored, with a plan-time warning, on the managed path or while `db_postgresdb_ssl_reject_unauthorized = false` |
| `postgres_ssl_mode` | Managed path only | Whether the Cloud SQL instance itself accepts plaintext connections at all |
