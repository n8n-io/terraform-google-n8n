# Task-runner sidecar: trusting a private/proxy CA

A live-proven reference for making the n8n task-runner sidecar's JavaScript
runner process trust a private or proxy certificate authority, by building a
custom runner image and a matching launcher configuration, then wiring both
in through this module's existing inputs. No module code changes, no Helm
postrender, and no module-generated launcher config: the module stays a
pass-through for both, exactly as documented.

## Why the module cannot do this itself

Chart 1.14.0 (the version this module pins) mounts exactly one file into the
`task-runner` container: the launcher configuration, at
`/etc/n8n-task-runners.json` via a `subPath` mount. The chart's top-level
`extraVolumeMounts` only reach the `n8n` container (main/worker/webhook
processor), and no other chart value places a file in the sidecar. There is
nothing the module could set to deliver a CA bundle into that container.

Even if there were, the JavaScript runner's sandbox has no `fetch`, and by
default only the `crypto` builtin is allowed (`NODE_FUNCTION_ALLOW_BUILTIN`
in the launcher's `env-overrides`). A Code node's
`this.helpers.httpRequest()` is executed by the n8n process itself, which
already trusts this module's `n8n_extra_ca_pem` bundle; it never touches the
runner's trust store and proves nothing about it. The only way for code
running *inside the runner process* to make an outbound TLS connection is for
the launcher configuration to allow a TLS-capable builtin or package, and for
the runner process to trust the certificate that connection presents. Both
of those are runner-image/launcher-config concerns, not module inputs the
chart exposes today.

The module already has the three inputs this reference uses:
`n8n_task_runner_image_repository`, `n8n_task_runner_image_tag`, and
`n8n_task_runner_custom_config` (see their descriptions in `variables.tf`,
and [`docs/troubleshooting.md`](../../troubleshooting.md#task-runner-custom-launcher-configuration-needs-a-matching-image-and-a-manual-restart)
for the whole-file-replacement and manual-restart caveats). The module
deliberately never reads or generates the launcher config; this reference is
how you use those inputs together.

## What this reference verified

Verified live on `terraform-google-n8n` at commit-time, chart 1.14.0, n8n
image `2.41.4`, runner image `n8nio/runners:2.41.4` (Alpine/musl + gcompat,
Node v26.7.0, Python 3.13.15), against a GKE queue-mode deployment
(`examples/split-ingress` topology) with a private internal ALB serving a
certificate signed by a private CA.

**1. Negative control, stock image and stock (default) launcher config.** A
Code node running `require('https')` in the runner is rejected outright by
the sandbox, before any TLS handshake is attempted:

```json
{"requireHttps":"blocked","error":"Module 'https' is disallowed [line 3]"}
```

**2. Positive control, custom image + `n8n-task-runners.test.json` applied
through the module's three inputs.** The same Code node, unchanged except
for the launcher config allowing the `https` builtin, makes a direct HTTPS
request from inside the runner process to the private ALB and gets a
verified response:

```json
{"requireHttps":"ok","result":"status:200 body:{\"status\":\"ok\"}"}
```

Confirmed from the sidecar container itself during this test: the worker
pod's `task-runner` container image was
`us-east4-docker.pkg.dev/<project>/xca-runners/runners:2.41.4-xca-ca-v1`;
`/etc/n8n-task-runners.json` inside it matched the pushed config; and
`/opt/n8n-custom-ca/ca.pem` existed, world-readable, with the private CA's
PEM content.

**3. Final state left running uses `n8n-task-runners.json` (production,
`NODE_FUNCTION_ALLOW_BUILTIN` left at the default `crypto`)**, with the same
custom image and `NODE_EXTRA_CA_CERTS` still set. Re-running the same Code
node against this config reproduces the negative control
(`Module 'https' is disallowed`), confirming that baking in the CA and
setting `NODE_EXTRA_CA_CERTS` alone does not widen the sandbox; a Code node
still needs its own builtin/package allowed, separately, before it can use
the trust this reference adds. `terraform plan` was clean (no changes)
against this final state, and all three n8n deployments were `Running`.

**Not covered: the Python runner.** The launcher configs in this reference
leave the Python entry exactly as the image's default; nothing was exercised
against the private CA from a Python Code node (see [Caveats](#caveats)).

## Step by step

### 1. Find the runner image tag you are actually running

```bash
kubectl -n <n8n_kube_namespace> get deploy n8n-worker -o jsonpath='{..image}'
```

The second image is the runner, e.g. `n8nio/runners:2.41.4`. Your custom
image must start from this exact tag: the launcher configuration's schema
and supported keys are defined by the runner image version
(`n8n_task_runner_image_tag`, or the n8n application image's tag when that
input is left `null`), and the module replaces the whole launcher config
file, it does not merge it.

### 2. Pull the default launcher config from that same image/tag

The default launcher configuration is not baked into the runner image; the
chart itself generates and mounts it (the same way it mounts a custom one),
so the only reliable way to get the exact default your version ships is to
exec into a sidecar that is *not* already running a custom config:

```bash
kubectl -n <n8n_kube_namespace> exec <worker-pod> -c task-runner -- \
  cat /etc/n8n-task-runners.json
```

[`n8n-task-runners.json`](./n8n-task-runners.json) and
[`n8n-task-runners.test.json`](./n8n-task-runners.test.json) in this
directory are derived from the `2.41.4` default this way; diff them against
your own pulled default if you are on a different runner version, the
`allowed-env` lists and default `env-overrides` have changed between
releases before.

### 3. Build the custom image

[`Dockerfile`](./Dockerfile) bakes a CA bundle into the image at
`/opt/n8n-custom-ca/ca.pem`, root-owned and world-readable (`0644`) so the
runner's non-root `runner` user (uid 1000) can read it without changing
image ownership elsewhere:

The build context must contain both the Dockerfile and your CA bundle, since
`COPY ${CA_BUNDLE}` resolves relative to the context, not your working
directory. Copy your CA bundle into this directory first (or build from a
staging directory that holds a copy of the `Dockerfile` and the bundle),
then build with this directory (or that staging directory) as the context:

```bash
cp <your-ca.pem> docs/reference/task-runner-custom-ca/
docker build \
  --build-arg RUNNER_IMAGE_TAG=<your runner tag, e.g. 2.41.4> \
  --build-arg CA_BUNDLE=<your-ca.pem> \
  -t <registry>/<repo>/runners:<tag>-ca-v1 \
  docs/reference/task-runner-custom-ca
docker push <registry>/<repo>/runners:<tag>-ca-v1
```

Use a distinct tag suffix (`-ca-v1`, `-ca-v2`, ...) every time you build,
including on CA rotation. Reusing the same tag risks a node serving a
cached, stale layer instead of pulling the new content, and it also gives
`terraform plan` nothing to diff on `n8n_task_runner_image_tag` (see
[Rotation](#rotation)).

`NODE_EXTRA_CA_CERTS` *adds* certificates to Node's existing trust store, so
the baked file only needs your private/proxy CA certificate(s), not a full
bundle. This is different from the Python entry; see
[Caveats](#caveats).

#### Building the image without Docker

This reference was built and pushed on a host with no `docker`/`podman`,
using [`crane`](https://github.com/google/go-containerregistry) (a
daemonless image tool) as a drop-in for the verification above; the
`Dockerfile` is still the primary deliverable for a customer with Docker
available.

```bash
curl -sL -o crane.tar.gz \
  https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz
tar xzf crane.tar.gz crane && chmod +x crane

gcloud auth print-access-token | \
  ./crane auth login us-east4-docker.pkg.dev -u oauth2accesstoken --password-stdin

# layer.tar contains only the new file(s), e.g. opt/n8n-custom-ca/ca.pem at
# mode 0644, owner root:root. Build it with any tool that gives you exact
# per-entry permissions (GNU tar's --mode/--owner/--group flags, or a few
# lines of Python's tarfile module); plain `tar cf layer.tar ca.pem` inherits
# your local file's ownership and mode, which is not reliably correct here.
./crane append -b n8nio/runners:<tag> -f layer.tar \
  -t <registry>/<repo>/runners:<tag>-ca-v1 --platform=linux/amd64
```

### 4. Write the launcher configuration

Start from the default you pulled in step 2, and add `NODE_EXTRA_CA_CERTS`
to the JavaScript entry's `env-overrides`, pointing at the path you baked
the CA into:

```json
"env-overrides": {
  "NODE_FUNCTION_ALLOW_BUILTIN": "crypto",
  "NODE_FUNCTION_ALLOW_EXTERNAL": "moment",
  "N8N_RUNNERS_HEALTH_CHECK_SERVER_HOST": "0.0.0.0",
  "NODE_EXTRA_CA_CERTS": "/opt/n8n-custom-ca/ca.pem"
}
```

[`n8n-task-runners.json`](./n8n-task-runners.json) in this directory is this
production variant: it does **not** widen `NODE_FUNCTION_ALLOW_BUILTIN`
beyond the default `crypto`. Trusting a CA is only useful once something in
the runner actually makes a TLS connection, so decide separately (and
narrowly) which builtin or `NODE_FUNCTION_ALLOW_EXTERNAL` package your Code
nodes are allowed to use; adding `https` to every deployment, as the test
variant below does, broadens what arbitrary Code node contents can do and is
not something this reference recommends by default.

[`n8n-task-runners.test.json`](./n8n-task-runners.test.json) is identical
except it also allows the `https` builtin, so `require('https')` works
directly from a Code node. It exists only to reproduce the
[verification](#what-this-reference-verified) above; its header `_comment`
field labels it as a test variant (confirmed harmless: the launcher parses
and ignores the extra field).

### 5. Wire it into Terraform

[`task-runner-ca.tf.example`](./task-runner-ca.tf.example) shows a
`kubernetes_namespace_v1` creating the namespace, a `kubernetes_config_map_v1`
holding the launcher config in that namespace, and the three module inputs
that reference the ConfigMap and the custom image. The namespace is created
outside `module.n8n` (with `create_namespace = false` and
`n8n_kube_namespace` passed to the module) because the ConfigMap must exist
before `module.n8n` applies, since the module input references the
ConfigMap's name, but the module only creates the namespace as part of its
own apply; on a fresh deployment the ConfigMap would otherwise fail with
"namespace not found". Copy the snippet into your own root module, next to
your `module "n8n"` block, and adjust the repository/tag/namespace to match
your deployment.

```bash
terraform plan
terraform apply
```

### 6. Restart to pick up the change

Neither a new ConfigMap *content* nor a new container image under an
existing tag triggers a pod rollout the module's `helm_release` would
diff on its own in every case; a new `n8n_task_runner_image_tag` value does
cause a Helm upgrade (because it is a chart value), but the module never
reads the ConfigMap's contents, so edits to the file your
`n8n_task_runner_custom_config.config_map_name` points at are invisible to
`terraform plan`. Restart explicitly after every apply that is supposed to
change runner behavior:

```bash
kubectl -n <n8n_kube_namespace> rollout restart deployment n8n-main n8n-worker
```

### 7. Verify

[`workflow.json`](./workflow.json) is the Code node used in both controls
above; edit its `host`/`servername`/`path` to point at your own private
endpoint. [`verify.sh`](./verify.sh) logs into n8n's REST API from inside
the cluster, creates and activates the workflow, triggers its webhook, and
asserts the result against an explicit `--expect` mode. Requires `kubectl`
pointed at the cluster, an n8n owner account, and `python3` on the host
(used to build the login payload and parse the webhook's JSON response).

Run it once with `--expect blocked` before this reference is applied: it
asserts `requireHttps` is `"blocked"` against the default config (or against
the test-variant config on the stock image, before your CA is baked in,
where the runner's TLS attempt still fails, just with a different error:
see the script's assertion failure message for the raw response). Run it
again with `--expect ok` after applying, which additionally requires
`status:200` in `result`, true once the custom image, the test launcher
config, and a restart are all in place. Either mode exits non-zero with the
full response on a mismatch.

```bash
N8N_EMAIL=you@example.com N8N_PASSWORD='...' \
  ./docs/reference/task-runner-custom-ca/verify.sh --expect blocked

# ...apply the reference, restart, then...

N8N_EMAIL=you@example.com N8N_PASSWORD='...' \
  ./docs/reference/task-runner-custom-ca/verify.sh --expect ok
```

## Rotation

A CA renewal means a new image, not just a new file inside the same tag:

1. Rebuild the image with the renewed bundle, under a new tag suffix
   (`-ca-v2`, etc.), and push it.
2. Update `n8n_task_runner_image_tag` in your copy of `task-runner-ca.tf.example`
   to the new tag.
   This is a chart value, so `terraform apply` upgrades the Helm release.
3. `terraform apply`, then restart (step 6 above) so every pod picks up the
   new image and re-reads the (unchanged, in this case) launcher config.

Keep the old CA valid and the old image tag available until every workload
using the old trust anchor has rolled over; Kubernetes does not coordinate
this for you.

## Caveats

- **Whole-file replacement.** `n8n_task_runner_custom_config` replaces the
  launcher's entire built-in configuration; it is not layered on top of the
  image's defaults. Re-derive it from your own image/tag (step 2) rather
  than hand-editing the files in this directory, if your runner version's
  defaults differ.
- **Sandbox widening is explicit and separate.** Trusting a CA does nothing
  by itself. A Code node still needs the relevant builtin
  (`NODE_FUNCTION_ALLOW_BUILTIN`) or package
  (`NODE_FUNCTION_ALLOW_EXTERNAL`) allowed before it can use that trust;
  decide that allowlist based on what your workflows actually need, not by
  copying the test variant.
- **Python: not configured.** The Python entry is left at the image default.
  Python's `ssl` module treats `SSL_CERT_FILE` as a *replacement* for the
  default trust store, not an addition like Node's `NODE_EXTRA_CA_CERTS`. If
  you need Python trust, bake a full bundle (the base image's own system CA
  bundle followed by your private/proxy CA, concatenated into one PEM), point
  `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` at it in the Python entry's
  `env-overrides`, and test it from a Python Code node. Without the merged
  bundle the runner would lose trust in every public CA. This reference does
  not ship that bundle and has not tested it.
- **Restart both `n8n-main` and `n8n-worker`.** In the queue-mode topology
  this reference tested, only `n8n-worker` runs the `task-runner` sidecar
  container; `n8n-main` does not. The troubleshooting guide's restart
  instructions name both deployments because the sidecar's container (and
  therefore the restart that matters) depends on your topology; restarting
  both is harmless and matches the module's own documented guidance.
- **Image pull.** The GKE node service account needs
  `artifactregistry.reader` on your custom image's repository (already
  granted by default to GKE node service accounts pulling from Artifact
  Registry in the same project). A different registry needs its own pull
  credentials via `n8n_image_pull_secrets`; this module does not add
  separate pull-secret support for the task-runner image specifically.
