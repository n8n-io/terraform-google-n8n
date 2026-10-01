# Ingress options: why GKE Ingress, and when to pick something else

This document is about *which ingress technology fits your deployment*, not
about the mechanics of replacing the module's own ingress. For the latter
(the exact outputs a `create_ingress = false` caller must consume, the
webhook-before-catch-all route-ordering rule, and the "200 with an HTML
body" misroute trap), see
[`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#ingress-and-application-autoscaling)
(the exact outputs), [`docs/istio-ingress.md`](./istio-ingress.md) (the
route-ordering rule and misroute trap), and
[`examples/split-ingress`](../examples/split-ingress). This document does
not repeat that contract; it only tells you when to leave the module's
default path and reach for `create_ingress = false` plus one of the
alternatives below.

## Why the module defaults to native GKE Ingress

When `create_ingress = true` (the default), the module provisions a classic
GKE (`gce`) `Ingress` backed by a global external Application Load Balancer,
using container-native load balancing (NEGs target pods directly, see
`n8n.tf`). Alongside it the module creates a `BackendConfig` (session
affinity + health check), a `FrontendConfig` (HTTP->HTTPS redirect), and,
when `tls_mode = "google_managed"`, a `ManagedCertificate` (all three in
`crds.tf`); the global static IP and optional Cloud DNS record live in
`dns.tf`. This stack was chosen because it needs no extra Kubernetes
controller to install or upgrade, Google manages the load balancer's control
plane, and Google-managed certificates auto-renew with no cert-manager
dependency. For a single-cluster, single-region n8n deployment reachable
from the public internet, this is the lowest-operational-overhead option
Google Cloud offers today (checked as of 2026-10-01, [GKE Ingress for
Application Load Balancers][gke-ingress-concepts]).

The tradeoff is the classic Ingress API's own ceiling: it has no weighted
traffic splitting, no header-based routing, and cannot route to Services in
more than one namespace from a single `Ingress` object, because the load
balancer and its routing rules are created together as one resource (checked
as of 2026-10-01, [Migrate Ingress to Gateway API][migrate-ingress-gateway]).
n8n's own routing needs (one catch-all route plus five webhook-family
prefixes, see the contract doc) fit comfortably inside that ceiling, which is
why the module has not needed to move off it.

## When GKE Gateway API fits better

Reach for the [Kubernetes Gateway API][gateway-api-concepts] instead of
`create_ingress = true` when you need any of:

- **Weighted traffic splitting or header-based routing** across n8n
  versions or route variants, e.g. canarying a new `n8n_image_tag` by
  percentage instead of an all-or-nothing rollout. Classic GKE Ingress has
  no equivalent; `HTTPRoute` with weighted `backendRefs` does (checked as of
  2026-10-01, [Migrate Ingress to Gateway API][migrate-ingress-gateway]).
- **Routing owned by a separate team or namespace from the Gateway itself.**
  Gateway API splits the load balancer (`Gateway`) from the routing rules
  (`HTTPRoute`), with first-class cross-namespace support via
  `ReferenceGrant`; a single GKE `Ingress` object cannot span namespaces at
  all (checked as of 2026-10-01, [Deploying Gateways][deploying-gateways]).
- **A shared load balancer frontend for n8n alongside other workloads**, so
  one global IP and certificate set serves multiple `HTTPRoute`s managed
  independently.

GKE exposes several `GatewayClass`es; the two most relevant to this module
are `gke-l7-global-external-managed` (global external Application Load
Balancer, Google's recommended default for internet-facing apps, Anycast
IP, the closest Gateway analogue to this module's default global-ALB
behavior) and `gke-l7-regional-external-managed` (external traffic pinned
to one region, useful if you need the load balancer itself confined to this
topology). `gke-l7-rilb` is the internal counterpart (see below). Avoid the
legacy `gke-l7-gxlb` class; Google documents it as built on the Classic
Application Load Balancer with no HTTP-to-HTTPS redirect and no custom
headers (checked as of 2026-10-01, [About Gateway API][gke-gateway-api]).

Two concrete Gateway limitations to check before switching: Gateway does not
infer health-check parameters the way Ingress does (if n8n's readiness probe
path or expectations differ from a bare `GET /` returning `200`, you need an
explicit `HealthCheckPolicy`), and `HTTPRoute` is the only supported Route
type (no `TCPRoute`/`UDPRoute`/`TLSRoute`), which is not a problem for n8n's
plain HTTP/HTTPS traffic (checked as of 2026-10-01, [Deploying
Gateways][deploying-gateways]).

This module does not create any Gateway API resource today; adding one
(`GatewayClass` selection, `Gateway`, `HTTPRoute` for the main/webhook split)
would be a new feature, not a documentation gap, and is out of scope here.
Set `create_ingress = false` and build the `Gateway`/`HTTPRoute` pair from
the same `n8n_main_service_name`/`n8n_webhook_service_name`/
`n8n_main_route_prefixes`/`n8n_webhook_route_prefixes` outputs
`examples/split-ingress` uses for its GKE-native Ingress pair.

## When an internal Application Load Balancer fits better

If n8n must stay off the public internet entirely (reachable only from
inside the VPC, a peered VPC, or over Cloud VPN/Interconnect), the module's
default public global external ALB is the wrong shape regardless of
Ingress-vs-Gateway choice. Two ways to get an internal L7 ALB on GKE:

- **Classic Ingress, internal variant**: set
  `kubernetes.io/ingress.class: "gce-internal"` on a caller-owned
  `kubernetes_ingress_v1` (this module's own `Ingress` always uses the
  external `gce` class; there is no module input to flip it). Requires a
  VPC-native cluster and NEG-backed Services, both already true of this
  module's GKE cluster (checked as of 2026-10-01, [Configuring Ingress for
  internal Application Load Balancers][gke-ingress-ilb]).
- **Gateway API, internal variant**: the `gke-l7-rilb` `GatewayClass`
  (regional internal Application Load Balancer; checked as of 2026-10-01,
  [About Gateway API][gke-gateway-api]).

Either way, set `create_ingress = false` and build the caller-owned Ingress
or Gateway the same way `examples/split-ingress`'s private Ingress already
does for its editor/API route (that example's `ingress.tf` is a working
internal-Ingress reference even though it is framed as a public/private
split rather than a fully-private deployment).

## When Istio or Cloud Service Mesh fits better

If you are already running Istio or Google's managed Cloud Service Mesh for
east-west traffic (mTLS between workloads, `PeerAuthentication`, traffic
policy), terminate north-south traffic at an Istio `Gateway`/`VirtualService`
instead of a second, parallel GKE Ingress. On GKE, an Istio ingress gateway
Service of type `LoadBalancer` provisions a Google Cloud Network Load
Balancer (L4) by default, with TLS terminated at the gateway pod rather than
at a Google-managed HTTPS proxy; a Google-managed certificate is still
usable by fronting the Istio gateway Service with a GKE `Ingress` (checked
as of 2026-10-01, [Cloud Service Mesh documentation][istio-ingress-gke]).
[`docs/istio-ingress.md`](./istio-ingress.md) already maps every output this
module emits onto the `VirtualService` shape (Service names, port, both
route-prefix lists) and reproduces the same route-ordering rule and misroute
trap documented in the customer-managed-infrastructure contract; read that
file for the mechanics. Use this document only to decide whether Istio is
the right entry point at all: pick it when your organization already
standardizes north-south and east-west routing on one mesh, not solely to
expose n8n.

## When a third-party ingress controller fits better

A caller already standardized on nginx-ingress, Contour, Traefik, or another
non-GKE-native controller can front n8n the same `create_ingress = false`
way, by pointing that controller's own `Ingress`/`HTTPRoute` objects at the
module's Service outputs. This module takes no position on which third-party
controller to run and creates none of their CRDs; the only thing to carry
over is the same routing contract every other alternative in this document
reproduces (webhook-family prefixes before the catch-all, same route-ordering
rule as `examples/split-ingress` and `docs/istio-ingress.md`).

## Summary

| You need | Reach for |
| --- | --- |
| Lowest operational overhead, single region, public internet, Google-managed cert | Module default (`create_ingress = true`, native GKE `gce` Ingress) |
| Weighted/canary traffic splits, header-based routing, or routing owned across namespaces | GKE Gateway API (`gke-l7-global-external-managed` / `gke-l7-regional-external-managed`) |
| No public internet exposure at all | Internal ALB: `gce-internal` Ingress class or the `gke-l7-rilb` GatewayClass |
| Already running Istio / Cloud Service Mesh for east-west traffic | Istio `Gateway`/`VirtualService`, see [`docs/istio-ingress.md`](./istio-ingress.md) |
| Already standardized on a non-GKE-native controller | That controller's own Ingress/Route objects against this module's Service outputs |

[gke-ingress-concepts]: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress "GKE Ingress for Application Load Balancers"
[migrate-ingress-gateway]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/migrate-ingress-gateway "Migrate Ingress to Gateway API"
[gateway-api-concepts]: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/gateway-api "About Gateway API"
[deploying-gateways]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways "Deploying Gateways"
[gke-gateway-api]: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/gateway-api "About Gateway API"
[gke-ingress-ilb]: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress "Configuring Ingress for internal Application Load Balancers"
[istio-ingress-gke]: https://cloud.google.com/service-mesh/docs "Cloud Service Mesh documentation"
