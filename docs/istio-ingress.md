# Routing with Istio instead of GKE Ingress

For a caller running Istio (Gateway API or the classic `Gateway`/`VirtualService`
CRDs) instead of a GKE `gce`/`gce-internal` Ingress Controller. This is
routing knowledge only: no new module input, output, resource, or example.
The module's existing `create_ingress = false` contract and Service/route
outputs already carry everything an Istio caller needs; this document maps
them onto Istio's own resources instead of `kubernetes_ingress_v1`.

## The contract this module gives you

With `create_ingress = false`, the module creates no global address, Cloud
DNS record, `kubernetes_ingress_v1`, `BackendConfig`, `FrontendConfig`, or
TLS resource. It still creates and stably names the workload Services and
still computes the same route/port outputs a managed ingress would consume:

| Output | Use in a Gateway/VirtualService |
| --- | --- |
| `n8n_kube_namespace` | Namespace the `VirtualService` and any Istio-specific Service references target |
| `n8n_main_service_name` | Backend for the editor/API catch-all route |
| `n8n_webhook_service_name` | Backend for the five webhook-family routes |
| `n8n_service_port` | Port both Services listen on (`http.port` in the `VirtualService`'s `route.destination`) |
| `n8n_main_route_prefixes` | Prefixes that must route to `n8n_main_service_name` |
| `n8n_webhook_route_prefixes` | Prefixes that must route to `n8n_webhook_service_name`: `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, `/mcp` |
| `n8n_ingress_hosts` | Every hostname (canonical `n8n_fqdn` plus any `n8n_additional_domains`) the caller-managed routing must serve |

Because these are the same outputs `examples/split-ingress` builds a
GKE-native customer-managed Ingress from (see that example's README and
`ingress.tf` for the equivalent GKE-native shape), an Istio caller and a
GKE-Ingress caller read identical route/port truth from the module; only the
CRD kind differs.

## Route ordering: the same rule as `examples/split-ingress`

A `VirtualService`'s `http.match` list is evaluated in order, first match
wins. Whether you expose one host or split public/private the way
`examples/split-ingress` does, **list every webhook-family prefix before any
catch-all route**:

```yaml
http:
  - match:
      - uri: { prefix: /webhook }
      - uri: { prefix: /webhook-waiting }
      - uri: { prefix: /form }
      - uri: { prefix: /form-waiting }
      - uri: { prefix: /mcp }
    route:
      - destination:
          host: <n8n_webhook_service_name>.<n8n_kube_namespace>.svc.cluster.local
          port: { number: <n8n_service_port> }
  - match:
      - uri: { prefix: / }
    route:
      - destination:
          host: <n8n_main_service_name>.<n8n_kube_namespace>.svc.cluster.local
          port: { number: <n8n_service_port> }
```

If a public-only `VirtualService` needs to expose webhooks but not the
editor, omit the catch-all route entirely (the same rule
`examples/split-ingress`'s public Ingress follows): **no editor/API route on
a public host.**

## The "200 with an HTML body" webhook-misroute trap

If a webhook route accidentally falls through to the main-service catch-all
(wrong match order, a typo'd prefix, or a rule matching on the wrong
`Gateway`), the request does not fail loudly. n8n's main process answers
with an HTTP 200 and an HTML body (the editor SPA shell), not a 404 or a
webhook error. A caller integration polling for a 200 status code sees
success and never notices the payload never reached a workflow. Verify a
misrouted webhook path with a body/content-type check, not a status-code
check alone, exactly as `examples/split-ingress`'s own verification guidance
does for the GKE-Ingress case.

## What this document does not cover

- Installing or configuring Istio itself, `PeerAuthentication`/`mTLS`
  policy, or a `Gateway`'s TLS termination. Those are entirely your
  service-mesh operator's decisions; the module has no opinion on them.
- A `DestinationRule` for load-balancing/circuit-breaking policy: the module
  makes no claim about what traffic policy is appropriate for your mesh.
- Any new Terraform resource, module input, or output. If you find yourself
  wanting the module to create the `Gateway`/`VirtualService` for you, that
  is out of scope for this document and would need its own proposal, the
  same way `examples/split-ingress` needed one for the GKE-native case.
