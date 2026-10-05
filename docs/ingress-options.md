# Ingress options: why GKE Ingress, and when to pick something else

This document is about *which ingress technology fits your deployment*, not
about the mechanics of replacing the module's own ingress. For the latter
(the exact outputs a `create_ingress = false` caller must consume, the
rule that webhook routes must win over the catch-all, and the "200 with an
HTML body" misroute trap), see
[`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#ingress-and-application-autoscaling)
(the exact outputs), [`docs/istio-ingress.md`](./istio-ingress.md) (the
route-ordering rule and misroute trap), and
[`examples/split-ingress`](../examples/split-ingress). This document does
not repeat that contract. It tells you when to leave the module's default
path, what you must rebuild when you do, and which alternative to reach for.

## Why the module defaults to native GKE Ingress

When `create_ingress = true` (the default), the module provisions a classic
GKE (`gce`) `Ingress` backed by a global external Application Load Balancer,
using container-native load balancing (NEGs target pods directly, see
`n8n.tf`). Alongside it the module creates a `BackendConfig` (session
affinity, backend timeout, health check, optional Cloud Armor policy), a
`FrontendConfig` (HTTP->HTTPS redirect, optional SSL policy), and, when
`tls_mode = "google_managed"`, a `ManagedCertificate` (all three in
`crds.tf`). The global static IP, optional Cloud DNS records, and optional
Cloud Armor policy live in `dns.tf`. This stack was chosen because it needs
no extra Kubernetes controller to install or upgrade, Google manages the
load balancer's control plane (checked as of 2026-10-01, [GKE Ingress for
Application Load Balancers][gke-ingress-concepts]), and Google Cloud renews
Google-managed certificates automatically, with no cert-manager dependency
(checked as of 2026-10-05, [Google-managed SSL
certificates][google-managed-certs]). For a single-cluster, single-region
n8n deployment reachable from the public internet, the maintainers consider
it the simplest option to operate today.

Google itself recommends moving to Gateway API over time, because Gateway is
a superset of Ingress. Google describes header-based matching and traffic
weighting as built into Gateway API but only possible in Ingress through
custom annotations (checked as of 2026-10-05, [About Gateway
API][gateway-api-concepts]). An `Ingress` object can also only reference
Services in its own namespace (checked as of 2026-10-05, [Kubernetes
Ingress API reference][k8s-ingress-api]). The module has not moved yet
because n8n's routing needs fit inside the classic Ingress API: one
catch-all route plus five webhook-family prefixes in one namespace (see the
contract doc).

## Before you set `create_ingress = false`

`create_ingress = false` is the entry point for every alternative below.
Read this section first. It applies whichever alternative you pick.

### Switching an existing deployment destroys module-owned ingress resources

On a deployment that already ran with `create_ingress = true`, flipping the
flag to `false` makes Terraform plan to destroy:

- the global static IP (`google_compute_global_address.lb` in `dns.tf`), so
  the public IP address changes,
- the Cloud DNS A-records, when `cloud_dns_zone_name` is set,
- the `Ingress`, `BackendConfig`, `FrontendConfig`, and `ManagedCertificate`,
- any pre-shared SSL certificate (`tls_mode = "custom"` or `"self_signed"`),
- the module-created Cloud Armor policy, when `ingress_source_cidrs` is set.

Any client still resolving the old IP address loses access once it is
destroyed. Setting the flag back to `true` creates a new IP address; it
does not restore the old one. Google recommends running the old and new
configurations side by side, testing the new one on its own IP address,
and then switching DNS (checked as of 2026-10-05, [Migrate Ingress to
Gateway API][migrate-ingress-gateway]). For this module:

1. Reserve a caller-owned static IP and a certificate the replacement
   ingress can serve before DNS moves. A Google-managed certificate that
   validates through the load balancer only becomes active once DNS points
   at that load balancer, so use one you can validate in advance (for
   example Certificate Manager with DNS authorization, or a certificate you
   supply).
2. Build the replacement ingress while the module's `Ingress` still serves
   traffic, and test it against its own IP address.
3. Move DNS to the new IP address. If you own DNS outside the module
   (`cloud_dns_zone_name = ""`), update your records. If the module
   manages them, transfer ownership first, because a zone cannot hold a
   second record set with the same name and type:
   1. In one change, add caller-owned `google_dns_record_set` resources
      matching the module's records (same name, type, TTL, and current IP),
      set `cloud_dns_zone_name = ""` on the module, and add a `moved` block
      per hostname, for example `from =
      module.n8n.google_dns_record_set.n8n["n8n.example.com"]` and `to =
      google_dns_record_set.n8n["n8n.example.com"]`.
   2. Save and review the plan. It must show only moves, with no DNS record
      created or destroyed. Apply that saved plan.
   3. Point the caller-owned records at the new IP address.

   Wait for the old record's TTL (300 seconds for module-managed records)
   and confirm traffic on the old load balancer has stopped. If you cannot
   transfer ownership, treat the switch as planned downtime instead: the
   module deletes its records in step 4, and the outage lasts until you
   recreate them and resolver caches expire, which can take longer than
   the TTL.
4. Set `create_ingress = false`. Save the plan (`terraform plan
   -out=ingress-cutover.tfplan`), review every resource it destroys, and
   apply that saved plan.

Two constraints affect step 2. A GKE Gateway cannot reference a Service that
a GKE Ingress also references (checked as of 2026-10-05, [Deploying
Gateways][deploying-gateways]). To build a Gateway while the module's
`Ingress` still runs, create separate caller-owned Services that select the
same n8n pods, the way `examples/split-ingress/services.tf` does. Otherwise,
remove the module's `Ingress` first and accept downtime during a planned
maintenance window. Also, the module's managed-ingress inputs (`tls_mode`,
`https_redirect`, `cloud_dns_zone_name`, `ingress_ssl_policy_name`,
`ingress_source_cidrs`, `existing_cloud_armor_policy_name`) are ignored
once `create_ingress = false`. The `ingress_tuning_ignored_when_existing`
check in `checks.tf` warns when they still differ from their defaults.

### Settings to review when replacing ingress

The module's `BackendConfig` and `FrontendConfig` carry settings that the
route contract does not mention. A replacement ingress does not get them
automatically. Decide for each one whether you need it, and how the
alternative expresses it:

| Setting | Module value | Where the module sets it |
| --- | --- | --- |
| Session affinity | `GENERATED_COOKIE`, 10800 s TTL, to keep each browser on one main pod for WebSocket/push connections | `BackendConfig`, `crds.tf` |
| Backend timeout | 300 s | `BackendConfig`, `crds.tf` |
| Health check | HTTP `GET /healthz` on port 5678 | `BackendConfig`, `crds.tf` |
| Source restriction | Cloud Armor policy from `ingress_source_cidrs` or `existing_cloud_armor_policy_name` | `BackendConfig`, `crds.tf`; policy in `dns.tf` |
| HTTP->HTTPS redirect | On (`https_redirect = true`) | `FrontendConfig`, `crds.tf` |
| SSL policy | `ingress_ssl_policy_name`, when set | `FrontendConfig`, `crds.tf` |
| TLS certificate | Depends on `tls_mode` | `crds.tf` (`ManagedCertificate`), `dns.tf` (pre-shared certificate), or `n8n.tf` (caller's TLS Secret for `tls_mode = "secret"`) |
| Static IP and DNS | Global static IP, optional Cloud DNS records | `dns.tf` |

Not every alternative supports every setting in the same way, and support
differs between Ingress classes (checked as of 2026-10-05, [Ingress
configuration feature comparison][gke-ingress-config]). The Gateway and
internal load balancer sections below name the Google Cloud equivalents
and known gaps.

## When GKE Gateway API fits better

Reach for the [Kubernetes Gateway API][gateway-api-concepts] instead of
`create_ingress = true` when you need any of:

- **Weighted traffic splitting or header-based routing**, for example a
  percentage canary between two n8n versions instead of an all-or-nothing
  rollout. `HTTPRoute` splits traffic with weighted `backendRefs` and
  routes on headers with `matches.headers` (checked as of 2026-10-05,
  [About Gateway API][gateway-api-concepts] and [Deploying
  Gateways][deploying-gateways]). This module deploys one n8n release, so a
  canary needs a second, separately deployed set of backends. The load
  balancer picks a weighted backend before it applies session affinity, so
  do not put weights on the same rule as the editor's sticky sessions
  (checked as of 2026-10-05, [Configure Gateway resources using
  Policies][gateway-policies]).
- **Routing owned by a separate team or namespace from the Gateway itself.**
  Gateway API splits the load balancer (`Gateway`) from the routing rules
  (`HTTPRoute`). An `HTTPRoute` in another namespace attaches to a
  `Gateway` when the Gateway's `listeners[].allowedRoutes` permits that
  namespace and the route names the Gateway in `parentRefs` (checked as of
  2026-10-05, [Gateway API cross-namespace
  routing][gateway-api-multiple-ns]). A `ReferenceGrant` is a separate
  permission. It lets an `HTTPRoute` reference a backend Service, or a
  `Gateway` reference a TLS Secret, in another namespace (checked as of
  2026-10-05, [About Gateway API][gateway-api-concepts]). A single GKE
  `Ingress` object cannot span namespaces at all.
- **A shared load balancer frontend for n8n alongside other workloads**, so
  one IP and certificate set serves multiple `HTTPRoute`s managed
  independently.

GKE exposes several `GatewayClass`es. The two external ones relevant to
this module are:

- `gke-l7-global-external-managed`: global external Application Load
  Balancer. This is the closest Gateway analogue to the module's default
  global load balancer.
- `gke-l7-regional-external-managed`: regional external Application Load
  Balancer. Use it when the load balancer frontend itself must run in one
  region, for example for data residency.

`gke-l7-rilb` is the internal counterpart (see below). For a global
external load balancer, prefer `gke-l7-global-external-managed` over the
`gke-l7-gxlb` class, which Google builds on the classic Application Load
Balancer (checked as of 2026-10-05, [About Gateway API][gateway-api-concepts]).
`gke-l7-gxlb` does not support custom request and response headers, path
redirects, or URL rewrites (checked as of 2026-10-05, [Deploying
Gateways][deploying-gateways]).

Check these requirements before switching (checked as of 2026-10-05,
[Deploying Gateways][deploying-gateways]):

- Gateway API must be enabled on the cluster, and Gateway API needs a
  VPC-native cluster.
- The regional classes (`gke-l7-regional-external-managed` and
  `gke-l7-rilb`) need a proxy-only subnet in the cluster's region. The
  module's VPC (`network.tf`) does not create one;
  `examples/split-ingress/network.tf` shows how to add it.
- `HTTPRoute` is the only supported Route type (no
  `TCPRoute`/`UDPRoute`/`TLSRoute`). This is not a problem for n8n's
  HTTP/HTTPS traffic.

A Gateway cannot use a `BackendConfig` or `FrontendConfig`. Recreate the
settings from the table above with Gateway resources instead (checked as of
2026-10-05, [Deploying Gateways][deploying-gateways] and [Configure Gateway
resources using Policies][gateway-policies]):

- **Health check**: Gateway does not infer health-check parameters from
  pod probes, and defaults to `GET /`. Add a `HealthCheckPolicy` for each
  backend Service that keeps the module's `/healthz` path on port 5678.
- **Session affinity**: a `GCPBackendPolicy` or `GCPTrafficDistributionPolicy`
  on the main Service.
- **Backend timeout and Cloud Armor**: a `GCPBackendPolicy` (`timeoutSec`,
  `securityPolicy`). A regional Gateway needs a regional Cloud Armor policy.
- **SSL policy**: a `GCPGatewayPolicy` on the Gateway. A regional Gateway
  needs a regional SSL policy.
- **HTTP->HTTPS redirect**: an `HTTPRoute` on the HTTP listener with a
  `RequestRedirect` filter (`scheme: https`).
- **TLS certificate**: Gateway cannot generate a Google-managed certificate
  from a `ManagedCertificate` resource. Use Certificate Manager, a manually
  created Google-managed SSL certificate, or a Kubernetes TLS Secret.

This module does not create any Gateway API resource today. Adding one
(`GatewayClass` selection, `Gateway`, `HTTPRoute` for the main/webhook
split) would be a new feature, not a documentation gap, and is out of scope
here. Set `create_ingress = false` and build the `Gateway`/`HTTPRoute` pair
from the module's `n8n_main_service_name`, `n8n_webhook_service_name`,
`n8n_service_port`, `n8n_main_route_prefixes`, and
`n8n_webhook_route_prefixes` outputs. `examples/split-ingress` shows the
other option: it creates its own Services and consumes only the port and
route-prefix outputs.

## When an internal Application Load Balancer fits better

If n8n must stay off the public internet entirely (reachable only from
inside the VPC, a peered VPC, or over Cloud VPN/Interconnect), the module's
default public global external load balancer is the wrong shape, whether
you use Ingress or Gateway. Two ways to get an internal L7 load balancer on
GKE:

- **Classic Ingress, internal variant**: set
  `kubernetes.io/ingress.class: "gce-internal"` on a caller-owned
  `kubernetes_ingress_v1`. This module's own `Ingress` always uses the
  external `gce` class; there is no module input to change it.
- **Gateway API, internal variant**: the `gke-l7-rilb` `GatewayClass`
  (regional internal Application Load Balancer). Apply the Gateway policy
  list from the previous section. A `GCPGatewayPolicy` with
  `allowGlobalAccess: true` lets clients in other regions reach it. Set it
  before the Gateway serves traffic: adding it to an existing Gateway
  recreates the load balancer and can cause up to 15 minutes of
  unavailability (checked as of 2026-10-05, [Configure Gateway resources
  using Policies][gateway-policies]).

Both variants need networking the module does not create (checked as of
2026-10-05, [Configuring Ingress for internal Application Load
Balancers][gke-ingress-ilb] and [Deploying Gateways][deploying-gateways]):

- **A proxy-only subnet** (`purpose = "REGIONAL_MANAGED_PROXY"`) in the
  cluster's region and VPC.
- **For `gce-internal`, a firewall rule** that lets the proxy-only subnet
  reach the n8n pods on port 5678. The Ingress controller creates the
  health-check firewall rule, but not this one.

The other prerequisites (VPC-native cluster, NEG-backed Services) are
already true of the cluster this module creates. More limits apply to
`gce-internal`:

- **No Google-managed certificates.** Serve TLS from a Kubernetes TLS
  Secret or a pre-shared regional SSL certificate.
- **No global access.** Clients must be in the load balancer's region.
  Google recommends an internal Gateway if you need global access.
- **No `FrontendConfig`.** Google limits `FrontendConfig` to external
  Ingress, so the module's HTTP->HTTPS redirect and SSL policy settings
  have no `gce-internal` equivalent. Google's feature comparison lists SSL
  policies for internal load balancers only through Gateway.
- **No Cloud Armor listed.** The same feature comparison does not list
  Cloud Armor support for internal Ingress, so the module's
  `ingress_source_cidrs` restriction does not carry over. Plan source
  restriction separately (checked as of 2026-10-05, [Ingress configuration
  feature comparison][gke-ingress-config]).

Either way, set `create_ingress = false` and build the caller-owned Ingress
or Gateway the same way `examples/split-ingress`'s private Ingress already
does for its editor/API route. That example's `network.tf` creates the
proxy-only subnet and the proxy firewall rule, `services.tf` creates its
own Services that select the n8n pods, and `tls.tf` serves the private
hostname from a Kubernetes TLS Secret. It disables plain HTTP on the
private Ingress instead of redirecting it. The example is framed as a
public/private split and is plan-tested with mocked providers, not yet
verified against a live GKE cluster. Its private half is still the closest
reference this repository has for a fully private deployment.

## When Istio or Cloud Service Mesh fits better

If you are already running Istio or Google's managed Cloud Service Mesh for
east-west traffic (mTLS between workloads, `PeerAuthentication`, traffic
policy), terminate north-south traffic at an Istio `Gateway`/`VirtualService`
instead of running a second, parallel GKE Ingress. The default setup puts
an L4 Network Load Balancer in front of the Istio ingress gateway pods, and
TLS terminates at the gateway pods. You can also put an external
Application Load Balancer (through GKE Gateway or Ingress) in front of the
mesh ingress gateway. That keeps Google-managed certificates, Cloud Armor,
and edge TLS termination while the mesh still handles routing inside the
cluster (checked as of 2026-10-05, [From edge to mesh: Expose service mesh
applications through GKE Gateway][edge-to-mesh]).

[`docs/istio-ingress.md`](./istio-ingress.md) already maps every output this
module emits onto the `VirtualService` shape (Service names, port, both
route-prefix lists) and covers the route-ordering rule and misroute trap.
Read that file for the mechanics. Use this document only to decide whether
Istio is the right entry point at all: pick it when your organization
already standardizes north-south and east-west routing on one mesh, not
solely to expose n8n.

## When a third-party ingress controller fits better

A caller already standardized on nginx-ingress, Contour, Traefik, or another
non-GKE-native controller can front n8n the same `create_ingress = false`
way, by pointing that controller's own `Ingress`/`HTTPRoute` objects at the
module's Service outputs. This module takes no position on which third-party
controller to run and creates none of their CRDs. Carry over two things:

- **The routing contract.** Every webhook-family prefix must route to the
  webhook Service, never to the catch-all. How you guarantee that depends
  on the controller: Istio matches in list order, while Ingress and Gateway
  implementations generally prefer the longest matching prefix. See
  `examples/split-ingress` and `docs/istio-ingress.md`.
- **The settings table** in [Settings to review when replacing
  ingress](#settings-to-review-when-replacing-ingress), expressed in that
  controller's own configuration.

## Summary

| You need | Reach for |
| --- | --- |
| Module-managed public ingress, single-region backend, Google-managed certificate | Module default (`create_ingress = true`, native GKE `gce` Ingress) |
| Weighted/canary traffic splits, header-based routing, or routing owned across namespaces | GKE Gateway API (`gke-l7-global-external-managed`, or `gke-l7-regional-external-managed` for a regional frontend) |
| No public internet exposure at all | Internal load balancer: `gce-internal` Ingress class or the `gke-l7-rilb` GatewayClass, plus a proxy-only subnet |
| Already running Istio / Cloud Service Mesh for east-west traffic | Istio `Gateway`/`VirtualService`, see [`docs/istio-ingress.md`](./istio-ingress.md) |
| Already standardized on a non-GKE-native controller | That controller's own Ingress/Route objects against this module's Service outputs |

Every row except the first starts with `create_ingress = false`. Read
[Before you set `create_ingress = false`](#before-you-set-create_ingress--false)
first.

[gke-ingress-concepts]: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress "GKE Ingress for Application Load Balancers"
[migrate-ingress-gateway]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/migrate-ingress-gateway "Migrate Ingress to Gateway API"
[gateway-api-concepts]: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/gateway-api "About Gateway API"
[deploying-gateways]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways "Deploying Gateways"
[gateway-policies]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources "Configure Gateway resources using Policies"
[gateway-api-multiple-ns]: https://gateway-api.sigs.k8s.io/guides/multiple-ns/ "Gateway API: cross-namespace routing"
[gke-ingress-ilb]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress "Configuring Ingress for internal Application Load Balancers"
[gke-ingress-config]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration "Ingress configuration"
[google-managed-certs]: https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs "Use Google-managed SSL certificates"
[k8s-ingress-api]: https://kubernetes.io/docs/reference/kubernetes-api/service-resources/ingress-v1/ "Kubernetes Ingress API reference"
[edge-to-mesh]: https://docs.cloud.google.com/architecture/exposing-service-mesh-apps-through-gke-ingress "From edge to mesh: Expose service mesh applications through GKE Gateway"
