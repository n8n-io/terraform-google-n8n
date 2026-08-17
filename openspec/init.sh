#!/usr/bin/env bash
# Ralph environment bootstrap + smoke check for terraform-google-n8n.
#
# Brings the module to a runnable state and runs the plan-time quality checks
# at the module root. No Google Cloud credentials are needed; the test suite
# uses mocked providers. Safe to run repeatedly.
#
# The full pre-commit loop (all five examples, tflint, terraform-docs drift)
# is documented in AGENTS.md under "Local development loop".
set -euo pipefail

cd "$(dirname "$0")/.."

# The veksh/godaddy-dns provider requires credentials even in plan-time
# tests; stub them unless the caller already set real values.
export GODADDY_API_KEY="${GODADDY_API_KEY:-stub}"
export GODADDY_API_SECRET="${GODADDY_API_SECRET:-stub}"

for tool in terraform tflint terraform-docs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool (see AGENTS.md for install hints)" >&2
    exit 1
  fi
done

echo "==> terraform fmt -check -recursive"
terraform fmt -check -recursive

echo "==> terraform init (module root, no backend)"
terraform init -backend=false -input=false >/dev/null

echo "==> terraform validate (module root)"
terraform validate

echo "==> terraform test (module root, mocked providers)"
terraform test

echo "OK: smoke check passed"
