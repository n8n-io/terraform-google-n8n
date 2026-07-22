# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md, Stability & versioning](./README.md#stability--versioning).

## [0.1.0] - 2026-07-21

Initial release.

### Added

- Production-grade n8n queue-mode deployment on Google Kubernetes Engine
  (GKE): multiple n8n main instances, dedicated worker pods, and webhook
  processors, fronted by a native GKE Ingress (Google Cloud L7 load
  balancer). Requires an n8n Enterprise license for multi-main.
- Regional, VPC-native GKE cluster with a managed node pool and native
  node-pool autoscaling, plus Workload Identity so pods authenticate to
  Google Cloud APIs without static keys.
- Cloud SQL for PostgreSQL over Private Service Access, with regional HA
  and configurable tier, disk, and version.
- Memorystore for Redis over Private Service Access, with optional AUTH.
- Google Cloud Storage bucket for n8n binary data, accessed through the
  S3-compatible endpoint via an HMAC key (with a bring-your-own-key mode
  for projects that cannot relax the service-account-key org policy).
- KEDA-based worker autoscaling driven by Redis queue depth, plus a CPU
  HPA for webhook processors.
- TLS options via `tls_mode`: `google_managed` (default, ManagedCertificate),
  `secret` (existing Kubernetes TLS secret, e.g. cert-manager), `custom`
  (bring-your-own PEM), and `self_signed`.
- Optional Cloud DNS A-record management, or bring your own DNS.
- Configurable Private Service Access teardown pause
  (`psa_cleanup_destroy_duration`) so `terraform destroy` clears the
  peering cleanly.
- Example roots: `small`, `medium`, `large`, `cloudflare` (cert-manager
  plus Cloudflare DNS-01), and `godaddy` (GoDaddy-managed DNS).
- Plan-time `terraform test` suites at the module root and in every
  example, using mocked providers so they run offline.
- Dedicated least-privilege service account for the GKE node pool
  (logging, monitoring, and Artifact Registry roles only), instead of the
  project's default Compute Engine service account.
- Pinned KEDA Helm chart version, configurable via `keda_chart_version`,
  so applies are reproducible instead of floating to the latest chart.
- GCS bucket hardening: public access prevention enforced and a lifecycle
  rule that deletes noncurrent object versions beyond the newest three.
- Fail-fast cross-variable validations for the BYO HMAC inputs
  (`gcs_hmac_*`) and an RFC1035 naming check on `cluster_name`, so
  misconfigurations stop the plan instead of surfacing mid-apply.

[0.1.0]: https://github.com/n8n-io/terraform-google-n8n/releases/tag/v0.1.0
