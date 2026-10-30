#!/usr/bin/env bash
# Verification recipe for the task-runner private-CA reference.
#
# Logs into n8n's REST API from inside the cluster, creates and activates
# workflow.json (edit its Code node's host/servername/path first), triggers
# its webhook, asserts the result, and deletes the workflow again on exit. Run it once with --expect blocked
# against the stock image/config as a negative control, then again with
# --expect ok after applying task-runner-ca.tf.example (with
# n8n-task-runners.test.json) as the positive proof.
#
# Requires: kubectl pointed at the cluster, an n8n owner account, and
# python3 on the host (used to build the login payload and parse JSON
# responses).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: verify.sh --expect ok|blocked|untrusted

  --expect ok         Positive proof: the custom image + test launcher config
                      (n8n-task-runners.test.json) trust the private CA.
                      Asserts requireHttps == "ok" and "status:200" appears
                      in the Code node's result.
  --expect blocked    Negative control for the default/production launcher
                      config (n8n-task-runners.json or the stock one): it
                      rejects require('https') outright. Asserts
                      requireHttps == "blocked".
  --expect untrusted  Negative control for the TEST launcher config
                      (n8n-task-runners.test.json) on an image that does not
                      have your CA baked in: https is allowed, so the runner
                      attempts TLS and the certificate check fails. Asserts
                      requireHttps == "ok" and the result is an err: entry
                      carrying a certificate-verification code.

Environment:
  N8N_NAMESPACE   Namespace n8n runs in (default: n8n).
  N8N_EMAIL       n8n owner/admin account email (required).
  N8N_PASSWORD    Password for that account (required).
  WORKFLOW_FILE   Path to the workflow to import (default: workflow.json
                  next to this script).
  TEST_POD_NAME   Name for the disposable curl pod this script creates and
                  deletes (default: task-runner-ca-verify-client). Change
                  this if it collides with a pod already in the namespace.
  TEST_POD_IMAGE  Image for that pod (default: curlimages/curl:8.11.0).
  CLEANUP_TIMEOUT Seconds each cleanup request may take (default: 15).
EOF
}

expect=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect)
      if [ $# -lt 2 ]; then
        usage
        exit 2
      fi
      expect="$2"
      shift 2
      ;;
    --expect=*)
      expect="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
if [ "$expect" != "ok" ] && [ "$expect" != "blocked" ] && [ "$expect" != "untrusted" ]; then
  usage
  exit 2
fi

: "${N8N_NAMESPACE:=n8n}"
: "${N8N_EMAIL:?set N8N_EMAIL to an n8n owner/admin account}"
: "${N8N_PASSWORD:?set N8N_PASSWORD for that account}"
: "${WORKFLOW_FILE:=$(dirname "$0")/workflow.json}"
: "${TEST_POD_NAME:=task-runner-ca-verify-client}"
: "${TEST_POD_IMAGE:=curlimages/curl:8.11.0}"

echo "Starting a disposable curl pod..." >&2
kubectl -n "$N8N_NAMESPACE" run "$TEST_POD_NAME" --image="$TEST_POD_IMAGE" \
  --restart=Never --command -- sleep 600
exec_curl() { kubectl -n "$N8N_NAMESPACE" exec "$TEST_POD_NAME" -- curl -s "$@"; }

# Runs on every exit, including a failed assertion: deactivate, archive, and
# delete the workflow this run created (so its fixed webhook path is free for
# the next run and nothing stays reachable), then remove the client pod. Each
# step is best effort; a leftover workflow is reported by id. Every request
# is capped at CLEANUP_TIMEOUT seconds, so a stalled n8n cannot keep the
# script from exiting and removing the client pod.
: "${CLEANUP_TIMEOUT:=15}"
auth_cookie=""
wf_id=""
cleanup() {
  if [ -n "$wf_id" ] && [ -n "$auth_cookie" ]; then
    exec_curl --max-time "$CLEANUP_TIMEOUT" -X POST "http://n8n-main:5678/rest/workflows/${wf_id}/deactivate" \
      -H "Cookie: ${auth_cookie}" -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
    exec_curl --max-time "$CLEANUP_TIMEOUT" -X POST "http://n8n-main:5678/rest/workflows/${wf_id}/archive" \
      -H "Cookie: ${auth_cookie}" -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
    delete_resp=$(exec_curl --max-time "$CLEANUP_TIMEOUT" -X DELETE "http://n8n-main:5678/rest/workflows/${wf_id}" \
      -H "Cookie: ${auth_cookie}" 2>/dev/null || true)
    case "$delete_resp" in
      *'"data":true'*) echo "Cleaned up workflow ${wf_id}." >&2 ;;
      *) echo "WARNING: could not delete workflow ${wf_id}; deactivate and delete it in the n8n UI. Response: ${delete_resp}" >&2 ;;
    esac
  fi
  kubectl -n "$N8N_NAMESPACE" delete pod "$TEST_POD_NAME" --now --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
kubectl -n "$N8N_NAMESPACE" wait --for=condition=Ready "pod/$TEST_POD_NAME" --timeout=60s
# Pipes stdin (read by this function's caller) into the pod's curl via
# `kubectl exec -i`, so sensitive request bodies never appear in the
# container's argument vector (visible to anyone who can list processes on
# the node).
exec_curl_stdin() { kubectl -n "$N8N_NAMESPACE" exec -i "$TEST_POD_NAME" -- curl -s "$@"; }

echo "Logging in..." >&2
login_payload=$(N8N_EMAIL="$N8N_EMAIL" N8N_PASSWORD="$N8N_PASSWORD" python3 -c '
import json, os
print(json.dumps({
    "emailOrLdapLoginId": os.environ["N8N_EMAIL"],
    "password": os.environ["N8N_PASSWORD"],
}))
')
login_headers=$(printf '%s' "$login_payload" | exec_curl_stdin -i -X POST http://n8n-main:5678/rest/login \
  -H 'Content-Type: application/json' \
  --data-binary @-)
# Under `set -o pipefail`, `grep` finding no match would fail this whole
# pipeline and exit the script before the diagnostic below can print;
# `|| true` keeps the diagnostic branch reachable.
auth_cookie=$(printf '%s' "$login_headers" | grep -i '^Set-Cookie: n8n-auth=' | sed -E 's/^Set-Cookie: (n8n-auth=[^;]+);.*/\1/I' | tr -d '\r' || true)
if [ -z "$auth_cookie" ]; then
  echo "Login failed; response:" >&2
  printf '%s\n' "$login_headers" >&2
  exit 1
fi

echo "Creating workflow..." >&2
kubectl -n "$N8N_NAMESPACE" cp "$WORKFLOW_FILE" "$TEST_POD_NAME:/tmp/workflow.json"
create_resp=$(exec_curl -X POST http://n8n-main:5678/rest/workflows \
  -H "Cookie: ${auth_cookie}" -H 'Content-Type: application/json' \
  --data @/tmp/workflow.json)
wf_id=$(printf '%s' "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')
echo "Workflow id: $wf_id" >&2

echo "Activating..." >&2
version_id=$(exec_curl "http://n8n-main:5678/rest/workflows/${wf_id}" -H "Cookie: ${auth_cookie}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["versionId"])')
exec_curl -X POST "http://n8n-main:5678/rest/workflows/${wf_id}/activate" \
  -H "Cookie: ${auth_cookie}" -H 'Content-Type: application/json' \
  -d "{\"versionId\":\"${version_id}\"}" >/dev/null

echo "Triggering webhook..." >&2
webhook_resp=$(exec_curl http://n8n-webhook-processor:5678/webhook/task-runner-ca-verify)
printf '%s\n' "$webhook_resp" >&2

# Assert the result matches the requested mode instead of just printing it,
# so a regression (e.g. the runner TLS check silently failing) makes the
# script exit non-zero rather than looking like a pass.
webhook_resp="$webhook_resp" expect="$expect" python3 -c '
import json, os, sys

resp = os.environ["webhook_resp"]
expect = os.environ["expect"]
try:
    data = json.loads(resp)
except ValueError as e:
    print(f"Could not parse webhook response as JSON: {e}\nResponse: {resp}", file=sys.stderr)
    sys.exit(1)

require_https = data.get("requireHttps")
if expect == "blocked":
    if require_https != "blocked":
        print(
            f"--expect blocked failed: requireHttps was {require_https!r}, "
            f"wanted \"blocked\". Full response: {data}",
            file=sys.stderr,
        )
        sys.exit(1)
    print("OK: negative control confirmed (requireHttps: blocked).", file=sys.stderr)
elif expect == "untrusted":
    result = str(data.get("result", ""))
    tls_codes = (
        "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
        "UNABLE_TO_GET_ISSUER_CERT",
        "SELF_SIGNED_CERT_IN_CHAIN",
        "DEPTH_ZERO_SELF_SIGNED_CERT",
        "CERT_UNTRUSTED",
    )
    if require_https != "ok" or not (
        result.startswith("err:") and any(c in result for c in tls_codes)
    ):
        print(
            f"--expect untrusted failed: requireHttps was {require_https!r} "
            f"(wanted \"ok\") and result was {result!r} (wanted an err: "
            f"entry with a certificate-verification code). Full response: {data}",
            file=sys.stderr,
        )
        sys.exit(1)
    print("OK: negative control confirmed (runner rejected the untrusted certificate).", file=sys.stderr)
else:
    result = data.get("result", "")
    if require_https != "ok" or "status:200" not in str(result):
        print(
            f"--expect ok failed: requireHttps was {require_https!r} "
            f"(wanted \"ok\") and result was {result!r} "
            f"(wanted \"status:200\" in it). Full response: {data}",
            file=sys.stderr,
        )
        sys.exit(1)
    print("OK: positive proof confirmed (requireHttps: ok, status:200).", file=sys.stderr)
'
