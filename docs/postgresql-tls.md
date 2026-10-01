# PostgreSQL TLS and server-certificate verification

Both the module-managed Cloud SQL path and the external PostgreSQL path connect over TLS once `db_postgresdb_ssl_enabled = true`, but that setting alone only encrypts the connection: it does not check that the certificate the server presents actually belongs to the host n8n dialed. `db_postgresdb_ssl_reject_unauthorized` closes that gap, with one hard limitation on the module-managed Cloud SQL path that this document explains precisely so you do not enable a setting that fails at runtime.

## n8n's verification model has no partial mode

n8n's PostgreSQL driver (`pg`/node-postgres) exposes a single `rejectUnauthorized` flag, not libpq's separate `verify-ca` (validate the certificate chain, skip the hostname check) and `verify-full` (validate the chain and the hostname) modes. Setting `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=true` always performs both the chain check and a hostname/IP check against the certificate's Subject Alternative Names (SANs), via Node's TLS module. There is no environment variable this module (or n8n) exposes to request chain-only verification while skipping the hostname check.

This matters because of how Cloud SQL issues server certificates.

## Why this blocks the module-managed Cloud SQL path

This module always connects to its module-managed Cloud SQL instance over the instance's **private IP** (Private Service Access, never a public IP or a DNS name). Google's own documentation is explicit that Cloud SQL server certificates never name a private IP address in their SAN: hostname/IP verification against a Cloud SQL instance requires connecting through a DNS name that the certificate actually carries (the instance's default `<uid>.<project-dns-label>.<region>.sql.goog` name, or a custom SAN you configure), not a bare IP. The Terraform provider's own `dns_name` computed attribute on `google_sql_database_instance` is scoped to "PSC instances or public IP CAS instances" only, confirming there is no usable hostname path for this module's private-IP-only, Private-Service-Access topology, regardless of which `settings.ip_configuration.server_ca_mode` the instance uses (`GOOGLE_MANAGED_INTERNAL_CA` or `GOOGLE_MANAGED_CAS_CA`).

Put together: enabling `db_postgresdb_ssl_reject_unauthorized` against the module-managed instance would always fail the TLS handshake with a hostname/IP SAN mismatch, on every connection, every pod, every time. Rather than ship a `verify-full`-style toggle that silently breaks a working deployment, `db_postgresdb_ssl_reject_unauthorized`'s own `validation` block rejects the combination at plan time:

```text
db_postgresdb_ssl_reject_unauthorized requires db_postgresdb_ssl_enabled = true (an unencrypted connection has no certificate to verify) and create_postgres_instance = false (the module-managed Cloud SQL path connects over a private IP whose certificate never names that IP, so certificate verification always fails the TLS handshake there; see docs/postgresql-tls.md).
```

If your organization's TLS policy requires certificate verification against the module-managed Cloud SQL instance, this module does not currently support it; verification only works on the external PostgreSQL path (below). Reaching it on the managed path would require this module to additionally wire the instance's own DNS name as the connection host and set up VPC-internal DNS resolution for it, neither of which this module does today.

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

`db_postgresdb_ssl_ca_secret_ref` references an existing Kubernetes Secret (in the n8n namespace) holding the PEM-encoded CA bundle that issued the external server's certificate. The module never reads the Secret's value: it only mounts the named key read-only at `/etc/n8n-certs/postgres-ssl-ca.crt` on every n8n role (main, worker, webhook processor) and points `DB_POSTGRESDB_SSL_CA_FILE` at that path. A missing Secret or key fails at pod-start time, not at plan time.

Leaving `db_postgresdb_ssl_ca_secret_ref` null while `db_postgresdb_ssl_reject_unauthorized = true` is valid: verification then falls back to the pod image's bundled trust store, which succeeds only if the external server's certificate chains to a publicly trusted root CA already in that image.

## Server-side enforcement: `postgres_ssl_mode`

Independent of whether n8n's client verifies anything, `postgres_ssl_mode` (`variables_gcp.tf`) controls whether the module-managed Cloud SQL instance itself accepts unencrypted connections at all (`google_sql_database_instance.ip_configuration.ssl_mode`):

- `ALLOW_UNENCRYPTED_AND_ENCRYPTED` (the default) accepts both, matching n8n's own default `DB_POSTGRESDB_SSL_ENABLED=false` client behavior.
- `ENCRYPTED_ONLY` rejects plaintext connections at the server. This requires `db_postgresdb_ssl_enabled = true` (enforced by `postgres_ssl_mode`'s own `validation` block); otherwise every n8n pod's connection attempt is refused and n8n never reaches the database.

`ENCRYPTED_ONLY` is unaffected by the hostname-verification limitation above: it only forces encryption, never certificate identity, so it is safe to combine with the module-managed Cloud SQL path.

## Summary table

| Variable | Scope | What it changes |
| --- | --- | --- |
| `db_postgresdb_ssl_enabled` | Both paths | Whether n8n encrypts the connection at all (`DB_POSTGRESDB_SSL_ENABLED`) |
| `db_postgresdb_ssl_reject_unauthorized` | External path only | Whether n8n validates the server's certificate chain *and* hostname (`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED`); rejected when `create_postgres_instance = true` |
| `db_postgresdb_ssl_ca_secret_ref` | External path only | CA bundle n8n trusts for that verification; ignored (with a plan-time warning) on the managed path |
| `postgres_ssl_mode` | Managed path only | Whether the Cloud SQL instance itself accepts plaintext connections at all |
