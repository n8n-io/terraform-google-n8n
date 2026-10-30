# TLS-inspecting and TLS-terminating proxies

A customer proxy can sit on either side of n8n, or both. The two sides are
independent inputs, so any combination works:

| Proxy position | What breaks without configuration | Module inputs | You still own |
| --- | --- | --- | --- |
| **Outbound** (n8n to the internet, TLS-inspecting) | Node rejects the proxy's re-signed certificates (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`) | `n8n_extra_ca_pem` for the proxy CA, plus `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` in `n8n_extra_env` | The proxy itself, its allow-list, and which hosts bypass it |
| **Inbound** (client to the ingress, TLS-terminating or WAF/CDN) | n8n sees the proxy's address as the client and logs `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` on rate-limited routes | `n8n_proxy_hops` (the Google load balancer counts as 2, so one proxy in front of it is 3); `tls_mode = "custom"` or `"secret"` when the proxy must trust a private-CA origin certificate; `ingress_source_cidrs` to admit only the proxy's egress addresses (module-managed ingress only, `create_ingress = true`); `n8n_webhook_url` if the public webhook host differs (the editor stays on `n8n_fqdn`) | The proxy's own certificate, its trust of the origin certificate, and forwarding `X-Forwarded-For` / `X-Forwarded-Proto` |
| **Both** | Both rows above | Set both groups | Both |

`n8n_extra_ca_pem`, `n8n_proxy_hops`, and `n8n_extra_env` are exposed as
variables by every example under `examples/`. Set them in the example's
`terraform.tfvars` (pass the PEM with `-var "n8n_extra_ca_pem=$(cat proxy-ca.pem)"`,
since `file()` is not allowed in a `.tfvars` file). The examples mark
`n8n_extra_env` `sensitive = true`. That redacts a proxy password from normal
plan and apply output only: the value remains readable in Terraform state and
the Helm release values (see the authenticated-proxy note below). The examples'
`n8n_proxy_hops` guidance uses the hop count described under
[Inbound](#inbound-a-proxy-in-front-of-the-ingress). The inputs that depend
on the ingress (`tls_mode`, `ingress_source_cidrs`) are not passed through the
examples; set them on the module call where the example uses the
module-managed ingress.

## Outbound: trust the proxy's CA

```hcl
n8n_extra_ca_pem = file("${path.module}/proxy-ca.pem")   # certificates only

n8n_extra_env = [
  { name = "HTTPS_PROXY", value = "http://proxy.corp.example:3128" },
  { name = "HTTP_PROXY",  value = "http://proxy.corp.example:3128" },
  # Keep cluster-internal and Google API traffic off the proxy.
  { name = "NO_PROXY",    value = "localhost,127.0.0.1,.svc,.cluster.local,.googleapis.com,metadata.google.internal" },
]
```

- The PEM is stored in a module-managed Secret and mounted read-only at
  `/etc/n8n-certs/ca-bundle.crt` on the main, worker, and webhook-processor
  pods. `NODE_EXTRA_CA_CERTS` points at it. `NODE_EXTRA_CA_CERTS` itself stays
  rejected in `n8n_extra_env`.
- Node reads one file, so with `redis_transit_encryption_enabled = true` the
  bundle is the Memorystore CA followed by your PEM. Do not add the Redis CA
  yourself.
- Changing the PEM (or the Memorystore CA in the bundle) rolls the pods: the
  module sets a `checksum/extra-ca` pod annotation (sha256 of the bundle) on
  the main, worker, and webhook-processor pods.
- Private keys are rejected at plan time; supply certificates only.
- Setting `n8n_extra_ca_pem` back to `null` deletes the Secret before Helm
  rolls the pods, because Terraform destroys a removed dependency before it
  updates the release that referenced it. Pods that are already running keep
  their mounted copy. A pod from the old revision that is scheduled during the
  rollout stays in `ContainerCreating` with `FailedMount` events until the
  rollout replaces it. If the Helm upgrade fails, `atomic = true` rolls back to
  a revision that mounts the deleted Secret; set the PEM again and re-apply to
  recover, then remove it in a quieter window.
- An authenticated proxy works by putting the credentials in the proxy URL
  (`http://user:password@proxy.corp.example:3128`). Percent-encode the user
  name and password first (for example `@` as `%40`, `:` as `%3A`, `/` as
  `%2F`), or a reserved character splits the URL in the wrong place and the
  proxy rejects the request. Without credentials n8n's outbound requests fail
  (the proxy answers 407). `n8n_extra_env` values are plain text
  in Terraform state and Helm values, so treat the proxy password as stored
  there.

### Task-runner sidecar

The module does not deliver the CA to the task-runner sidecar. Chart 1.16.0
(the version this module pins) mounts only the launcher config into that container, and the chart's top-level
`extraVolumeMounts` apply to the n8n container only, so there is no chart value
that places a file in the sidecar. The runner's JavaScript sandbox has no
`fetch`, and requests from a Code node through `this.helpers.httpRequest` are
made by the n8n process, which does trust the bundle. If a custom runner
workload needs the CA itself, bake it into the image and point
`n8n_task_runner_image_repository` / `n8n_task_runner_image_tag` at it, with a
matching `n8n_task_runner_custom_config` launcher configuration that adds
`NODE_EXTRA_CA_CERTS`. See
[`docs/reference/task-runner-custom-ca/`](./reference/task-runner-custom-ca/README.md)
for a live-proven, step-by-step reference: why the module cannot do this
itself, a Dockerfile, both a production and a verification launcher config,
a Terraform snippet, and the exact negative/positive evidence this was
tested against.

## Inbound: a proxy in front of the ingress

```hcl
n8n_proxy_hops       = 3                  # customer proxy (1) + Google load balancer (2)
ingress_source_cidrs = ["203.0.113.0/24"] # the proxy's egress range
```

- `n8n_proxy_hops` sets `N8N_PROXY_HOPS` on every role. Express counts the
  immediate peer as the first hop, then reads `X-Forwarded-For` from right to
  left. The Google load balancer appends two entries, the client address it
  sees and its own forwarding-rule IP
  ([Google documentation](https://cloud.google.com/load-balancing/docs/https#x-forwarded-for_header)),
  so it counts as 2. The module-managed ingress alone is 2, and one customer
  proxy in front of it is 3. Too low a value makes n8n see the proxy's
  address as the client for every request. Null (the default) leaves n8n's
  own default in place; this differs from the AWS and Azure modules, which
  default to 1 for their single-entry load balancers.
- The count is only safe when every path to n8n crosses the same number of
  proxies. A client that reaches the load balancer directly while the count
  is sized for the proxy path can put any address in `X-Forwarded-For` and
  n8n uses it as the client IP, for example to get around per-IP rate limits
  ([Express documentation](https://expressjs.com/en/guide/behind-proxies.html)).
  With `create_ingress = true`, use `ingress_source_cidrs` so that only the
  proxy reaches the load balancer. With `create_ingress = false` (for example
  the split-ingress example), the module ignores `ingress_source_cidrs`;
  enforce the same allow-list on the ingress or load balancer you own.
- Google documents that the internal Application Load Balancer can strip an
  incoming `X-Forwarded-For` it receives from an intermediate proxy
  ([Google documentation](https://cloud.google.com/load-balancing/docs/l7-internal)).
  In that case the original client address never reaches n8n, whatever the
  count. With the split-ingress private editor ingress, check the address n8n
  records before you rely on it.
- For a proxy that verifies the origin certificate against a private CA, use
  `tls_mode = "custom"` (`tls_cert_pem` / `tls_key_pem`) or `tls_mode =
  "secret"` (a TLS Secret you create, named by `tls_secret_name`) with a
  certificate signed by that CA. With `google_managed` the proxy needs the
  public roots only.
- Changing `tls_mode` from `custom` to `secret` in place needs two applies. The
  first updates the Ingress but fails destroying the old
  `google_compute_ssl_certificate` with `resourceInUseByAnotherResource`,
  because the load balancer still references it; once GKE has switched the
  target proxy to the Secret (about a minute), the second apply removes it.
- `ingress_source_cidrs` applies only to the module-managed ingress
  (`create_ingress = true`). It is matched against the client address the load
  balancer sees, which for a proxy is its public egress address. Anything else
  gets a 403 from the load balancer (the TLS handshake still succeeds). List
  every address the proxy can egress from. Do not also admit clients that
  bypass the proxy, such as direct webhook senders, unless they go through
  the same number of proxies; see the hop-count note above.
- The module cannot configure the proxy. It must send `X-Forwarded-For` and
  `X-Forwarded-Proto`, and its `Host` header must match the hostname the
  ingress serves.
- `n8n_webhook_url` changes only the webhook base URL. The editor and its
  OAuth callbacks always use `https://<n8n_fqdn>`, so for editor traffic keep
  `n8n_fqdn`, the origin certificate, and the `Host` header the proxy forwards
  on the same hostname. Set `n8n_webhook_url` only when webhooks are served
  from a different public host.
- The editor's live updates use a WebSocket on `/rest/push`. The proxy must
  forward `Upgrade` / `Connection` (nginx needs `proxy_http_version 1.1` and
  `proxy_set_header Upgrade $http_upgrade`; without them the push request
  returns 500). n8n also rejects the connection with close code 1008
  (`Invalid origin!`) unless the browser's `Origin` matches the `Host` the
  proxy forwards. n8n's server pings every 60 seconds, so keep the proxy's idle
  timeout above that; a connection held open for 420 seconds through nginx and
  the internal load balancer (backend timeout 300) stayed up.

With the split-ingress example, the private editor ingress uses a certificate
you supply, so a private CA works there directly; the public webhook ingress
uses a Google-managed certificate.
