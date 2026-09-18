## Why

The Google module lacks several application controls and operational fixes available in the AWS module through release 0.4.0. Some apparently complete features also have gaps, including Redis command-channel isolation and editor URLs for split-host deployments.

## What changes

- Compare the complete AWS 0.4.0 interface and release history with the Google baseline. Record each feature group as a port, Google-specific adaptation, existing capability, or exclusion in `parity-matrix.md`.
- Add single-main queue mode with topology-aware autoscaling, rollout strategy, disruption budget, capacity estimates, and license guidance. Retain multi-main as the default.
- Add database health/acquisition tuning, queue lock/stall tuning, execution-save controls, task-runner launcher configuration and execution timeout, pod DNS, V8 heap limits, community registry settings, compression limits, and package-verification controls.
- Add caller-managed volume mounts and credential-overwrite Secret references. Accept a supplied encryption key for recovery and stop putting direct license keys in Helm values.
- Complete Redis namespace isolation and add an opt-in Redis exporter that trusts Memorystore's service CA and shares the n8n/KEDA connection contract.
- Correct editor/webhook base URLs, add additional managed hostnames and guarded ingress annotations, and provide a Google-native split-ingress example.
- Adapt backup controls to Cloud SQL backup-count retention and opt-in Memorystore RDB persistence. Do not invent Google equivalents of AWS `apply_immediately`.
- Add chart-rendering regression checks, complete input validation, a curated blocking security gate, and Google-specific upgrade and smoke-test documentation.
- **BREAKING:** Reject newly reserved environment variables and invalid inputs that previously passed. Document behavior changes, including corrected URLs and Redis command prefixes. Other breaking changes are allowed only with a stated reason, not to copy AWS naming.

## Capabilities

### New capabilities

- `main-topology`: Single-main and multi-main queue-mode behavior and maintenance safety.
- `redis-observability`: Optional, private Redis metrics with shared credentials, queue keys, and verified TLS.
- `release-verification`: Credential-free regression checks and an enforceable security baseline.

### Modified capabilities

- `application-portability`: Runtime controls, caller-managed mounts, and environment collision protection.
- `kubernetes-ownership`: Encryption-key recovery, license Secret handling, credential overwrites, additional hosts, and split ingress.
- `redis-connectivity`: Synchronize command-channel and Bull prefixes, not only queue/scaler keys.
- `capacity-guardrails`: Use the effective single-main ceiling and account for the optional exporter.
- `infrastructure-ownership`: Google-native backup controls and direct-key restore continuity.
- `operator-docs`: Upgrade guidance, feature/license boundaries, sizing corrections, and manual verification.

## Impact

Implementation will affect root Terraform inputs, locals, n8n/Redis/Cloud SQL/ingress/scaling resources, a new `observability.tf`, tests, CI, operator documentation, and examples. Keep the Google naming and ownership model, native GKE controllers, Workload Identity, and GCS HMAC contract. Keep Terraform 1.9 support and current provider/chart constraints unless a separately documented technical necessity is found.

The user selected all applicable gaps through AWS 0.4.0, justified pre-release breaking changes, and automated verification plus a manual Google Cloud checklist. A live apply, live upgrade, load test, release publication, and implementation of this proposal are not part of proposal preparation. Live infrastructure verification is not a completion gate for the later implementation.
