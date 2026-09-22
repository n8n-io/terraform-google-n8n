#!/usr/bin/env bash
# Runs the module's curated, blocking checkov baseline twice: once against
# the default tfvars (every count-gated resource at its default, usually 0),
# and once against tests/checkov/opt-in.tfvars, which flips on every switch
# that gates a resource checkov would otherwise silently drop from its report
# (checkov answers every check on a count-0 resource UNKNOWN, not FAILED, so
# it never appears at all - see AGENTS.md, "Static analysis").
#
# The opt-in pass also asserts checkov actually *evaluated* the opt-in
# resources (kubernetes_deployment_v1.redis_exporter and its Service), not
# just that the run happened to exit 0: --quiet suppresses passed_checks
# from checkov's own JSON output, so a resource that silently stayed
# skipped would otherwise pass this script with zero visible signal. This
# script therefore drops --quiet only on the opt-in JSON invocation.
#
# Mirrors the two-pass CI checkov job exactly; run this locally before
# pushing a change that touches a count-gated resource. Add its opt-in
# switch to tests/checkov/opt-in.tfvars at the same time, and to
# REQUIRED_OPT_IN_RESOURCES below, or this script's reachability check
# will fail.
#
# Requires: checkov and python3 on PATH, checkov pinned to the version this
# module's CI uses (see the checkov-action ref comment in
# .github/workflows/terraform-tests.yml). No credentials, no cluster, no
# live plan: checkov statically parses the Terraform source and its own
# resolved variable defaults/tfvars.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

if ! command -v checkov >/dev/null 2>&1; then
  echo "check-checkov.sh: checkov is not on PATH. Install the pinned version" >&2
  echo "named in .github/workflows/terraform-tests.yml's checkov job comment" >&2
  echo "(e.g. uv tool install checkov==3.3.17)." >&2
  exit 1
fi

OPT_IN_TFVARS="tests/checkov/opt-in.tfvars"
# Resources tests/checkov/opt-in.tfvars exists to unblind. Extend this list
# alongside a new entry in that file when a new count-gated resource is added.
REQUIRED_OPT_IN_RESOURCES=(
  "kubernetes_deployment_v1.redis_exporter"
  "kubernetes_service_v1.redis_exporter"
)

status=0

echo "==> checkov (default tfvars)"
if ! checkov -d . --framework terraform --compact --quiet; then
  echo "check-checkov.sh: default-pass checkov scan failed" >&2
  status=1
fi

echo
echo "==> checkov (opt-in tfvars: ${OPT_IN_TFVARS})"
opt_in_json="$(mktemp)"
trap 'rm -f "$opt_in_json"' EXIT
# Not --quiet: this run's JSON must carry passed_checks for the reachability
# check below. checkov's own exit code still reflects pass/fail.
checkov_exit=0
checkov -d . --framework terraform --compact --var-file "$OPT_IN_TFVARS" -o json >"$opt_in_json" 2>&1 || checkov_exit=$?

if ! python3 - "$opt_in_json" "$checkov_exit" <<'PYEOF'
import json
import sys

path, exit_code = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    data = json.load(f)
data = data if isinstance(data, list) else [data]

failed_any = False
for doc in data:
    for failed in doc.get("results", {}).get("failed_checks", []):
        print(f"FAILED (opt-in): {failed['check_id']} {failed['resource']}", file=sys.stderr)
        failed_any = True

if exit_code != 0 and not failed_any:
    print(
        f"opt-in checkov invocation exited {exit_code} with no parsed failed_checks; inspect it directly",
        file=sys.stderr,
    )
    failed_any = True

sys.exit(1 if failed_any else 0)
PYEOF
then
  echo "check-checkov.sh: opt-in-pass checkov scan failed" >&2
  status=1
fi

echo
echo "==> verifying the opt-in pass actually reached its target resources"
if ! python3 - "$opt_in_json" "${REQUIRED_OPT_IN_RESOURCES[@]}" <<'PYEOF'
import json
import sys

path = sys.argv[1]
required = sys.argv[2:]

with open(path) as f:
    data = json.load(f)
data = data if isinstance(data, list) else [data]

evaluated = set()
for doc in data:
    results = doc.get("results", {})
    for bucket in ("passed_checks", "failed_checks", "skipped_checks"):
        for c in results.get(bucket, []):
            evaluated.add(c.get("resource", ""))

missing = [r for r in required if not any(r in addr for addr in evaluated)]
if missing:
    print(
        "the opt-in pass never evaluated: " + ", ".join(missing) +
        ". tests/checkov/opt-in.tfvars no longer reaches it (a switch " +
        "default changed, or the resource was renamed/removed) - this is " +
        "exactly the silent count-0 blind spot this script exists to catch.",
        file=sys.stderr,
    )
    sys.exit(1)

print("reached: " + ", ".join(required))
PYEOF
then
  status=1
fi

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo
echo "check-checkov.sh: both passes clean and the opt-in pass reached its target resources"
