#!/usr/bin/env bash
# Verification recipe for the task-runner private-CA reference.
#
# Logs into n8n's REST API from inside the cluster, creates and activates
# workflow.json (edit its Code node's host/servername/path first), triggers
# its webhook, and prints the result. Run it once against the stock
# image/config as a negative control, then again after applying
# task-runner-ca.tf.example (with n8n-task-runners.test.json) as the positive proof.
#
# Requires: kubectl pointed at the cluster, and an n8n owner account.
set -euo pipefail

: "${N8N_NAMESPACE:=n8n}"
: "${N8N_EMAIL:?set N8N_EMAIL to an n8n owner/admin account}"
: "${N8N_PASSWORD:?set N8N_PASSWORD for that account}"
: "${WORKFLOW_FILE:=$(dirname "$0")/workflow.json}"
: "${TEST_POD_NAME:=task-runner-ca-verify-client}"
: "${TEST_POD_IMAGE:=curlimages/curl:8.11.0}"

echo "Starting a disposable curl pod..." >&2
kubectl -n "$N8N_NAMESPACE" run "$TEST_POD_NAME" --image="$TEST_POD_IMAGE" \
  --restart=Never --command -- sleep 600
trap 'kubectl -n "$N8N_NAMESPACE" delete pod "$TEST_POD_NAME" --now --ignore-not-found >/dev/null 2>&1' EXIT
kubectl -n "$N8N_NAMESPACE" wait --for=condition=Ready "pod/$TEST_POD_NAME" --timeout=60s

exec_curl() { kubectl -n "$N8N_NAMESPACE" exec "$TEST_POD_NAME" -- curl -s "$@"; }

echo "Logging in..." >&2
login_headers=$(exec_curl -i -X POST http://n8n-main:5678/rest/login \
  -H 'Content-Type: application/json' \
  -d "{\"emailOrLdapLoginId\":\"${N8N_EMAIL}\",\"password\":\"${N8N_PASSWORD}\"}")
auth_cookie=$(printf '%s' "$login_headers" | grep -i '^Set-Cookie: n8n-auth=' | sed -E 's/^Set-Cookie: (n8n-auth=[^;]+);.*/\1/I' | tr -d '\r')
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
exec_curl -i http://n8n-webhook-processor:5678/webhook/task-runner-ca-verify

echo "" >&2
echo "Deactivate/delete the workflow (PATCH .../${wf_id} {\"active\":false} then DELETE) when done." >&2
