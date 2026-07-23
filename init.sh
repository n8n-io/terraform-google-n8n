#!/usr/bin/env bash
# Ralph init script: bring the repo to a runnable state and run a smoke check.
# Safe to run repeatedly. Mirrors the local development loop in AGENTS.md.
set -euo pipefail

cd "$(dirname "$0")"

# The veksh/godaddy-dns provider requires credentials even in plan-time tests.
export GODADDY_API_KEY="${GODADDY_API_KEY:-stub}"
export GODADDY_API_SECRET="${GODADDY_API_SECRET:-stub}"

for tool in terraform tflint terraform-docs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "WARNING: $tool not found on PATH; install it before running quality checks." >&2
  fi
done

echo "==> Formatting check (git-tracked Terraform files only)"
# Local, git-ignored files (e.g. examples/*/terraform.tfvars from a real
# deployment) must not fail the smoke check.
git ls-files -z -- '*.tf' '*.tftest.hcl' | xargs -0 terraform fmt -check

run_checks() {
  local dir="$1"
  echo "==> Checking $dir"
  (
    cd "$dir"
    terraform init -backend=false -input=false >/dev/null
    terraform validate
    terraform test
  )
}

# Module root, then every example (mirrors the CI matrix).
run_checks .
for example in examples/*/; do
  run_checks "$example"
done

echo "==> Smoke check passed"
