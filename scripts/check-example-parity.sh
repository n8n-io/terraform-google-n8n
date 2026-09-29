#!/usr/bin/env bash
# Diffs the variable-name set every examples/*/variables.tf declares against
# examples/small's, and fails on any name present on only one side that is
# not in that example's own allowlist below. Also fails when an example
# still lets the module create Cloud SQL and/or GCS but its README has no
# "Production considerations" section.
#
# Local-only for now (not wired into CI): run it after adding a passthrough
# variable to one example to catch forgetting its siblings. Names only: a
# shared variable's type or default is not compared.
#
# A stale allowlist entry (naming a variable that no longer differs) fails
# too, so this script cannot silently rot into "everything is allowed".

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BASE_EXAMPLE="small"
EXAMPLES_DIR="examples"

# Every example that lets the module own Cloud SQL and/or GCS needs a
# "Production considerations" README section (see AGENTS.md). The three
# that don't are excluded here for a documented reason, not by omission.
#   customer-managed-everything: create_postgres_instance = false and
#     create_gcs_bucket = false; owns neither layer.
REQUIRE_PRODUCTION_CONSIDERATIONS=(
  small medium large cloudflare godaddy split-ingress
  customer-managed-cluster customer-managed-redis customer-managed-gcs
  worker-pools
)

variable_names() {
  python3 -c "
import re
import sys
with open(sys.argv[1]) as f:
    text = f.read()
for m in re.finditer(r'^variable\s+\"([a-z0-9_]+)\"', text, re.MULTILINE):
    print(m.group(1))
" "$1" | sort -u
}

# Each entry: space-separated variable names allowed to differ from
# examples/small, in the direction named. Extend both functions, in the same
# change, whenever a new example-specific variable is added deliberately.
# Plain case statements instead of associative arrays (declare -A) so the
# script runs under the bash 3.2 that macOS ships as /bin/bash.

missing_ok() {
  case "$1" in
    medium) echo "" ;;
    large) echo "" ;;
    cloudflare) echo "n8n_image_tag cloud_dns_zone_name n8n_additional_domains" ;;
    godaddy) echo "n8n_image_tag cloud_dns_zone_name n8n_additional_domains" ;;
    split-ingress) echo "n8n_image_tag cloud_dns_zone_name n8n_additional_domains" ;;
    customer-managed-cluster) echo "n8n_image_tag gke_deletion_protection" ;;
    customer-managed-redis) echo "n8n_image_tag" ;;
    customer-managed-gcs) echo "gcs_location n8n_image_tag manage_sa_key_org_policy gcs_force_destroy" ;;
    customer-managed-everything) echo "gcs_location n8n_image_tag cloud_dns_zone_name n8n_main_hpa_min_replicas manage_sa_key_org_policy postgres_backup_retained_backups postgres_transaction_log_retention_days gke_deletion_protection postgres_deletion_protection gcs_force_destroy" ;;
    worker-pools) echo "" ;;
    *) echo "" ;;
  esac
}

extra_ok() {
  case "$1" in
    medium) echo "postgres_machine_type postgres_disk_size postgres_availability_type redis_tier n8n_redis_timeout_threshold_ms redis_memory_size_gb gke_node_type gke_node_min_per_zone gke_node_max_per_zone gke_node_disk_size_gb gke_node_disk_type db_postgresdb_pool_size n8n_execution_concurrency_limit n8n_webhook_hpa_max_replicas n8n_webhook_hpa_min_replicas n8n_worker_concurrency n8n_worker_keda_max_replicas n8n_worker_keda_min_replicas" ;;
    large) echo "postgres_machine_type postgres_disk_size postgres_availability_type redis_tier n8n_redis_timeout_threshold_ms redis_memory_size_gb gke_node_type gke_node_min_per_zone gke_node_max_per_zone gke_node_disk_size_gb gke_node_disk_type db_postgresdb_pool_size n8n_execution_concurrency_limit n8n_webhook_hpa_max_replicas n8n_webhook_hpa_min_replicas n8n_worker_concurrency n8n_worker_keda_max_replicas n8n_worker_keda_min_replicas" ;;
    cloudflare) echo "cloudflare_zone_id cloudflare_api_token acme_email acme_server cert_manager_version" ;;
    godaddy) echo "godaddy_domain godaddy_api_key godaddy_api_secret" ;;
    split-ingress) echo "public_webhook_fqdn proxy_only_subnet_cidr internal_tls_cert_pem internal_tls_key_pem" ;;
    customer-managed-cluster) echo "existing_gke_cluster_name existing_gke_prerequisites_attestation" ;;
    customer-managed-redis) echo "redis_host redis_port redis_tls_enabled redis_username redis_password_secret_name" ;;
    customer-managed-gcs) echo "existing_gcs_bucket_name gcs_hmac_service_account_email gcs_hmac_access_id gcs_hmac_secret_name" ;;
    customer-managed-everything) echo "n8n_main_fixed_replicas existing_network_name existing_subnetwork_name existing_pods_range_name existing_services_range_name existing_gke_cluster_name existing_gke_prerequisites_attestation n8n_database_host n8n_database_password_secret_name redis_host redis_tls_enabled redis_password_secret_name existing_gcs_bucket_name gcs_hmac_service_account_email gcs_hmac_access_id gcs_hmac_secret_name n8n_kube_namespace" ;;
    # Sizing-equivalent to small apart from the node ceiling; the rest is the
    # EARLY ALPHA worker-pools surface (chart pin/attestation, default-worker
    # KEDA bounds) the example exists to demonstrate.
    worker-pools) echo "gke_node_max_per_zone n8n_chart_version n8n_chart_repository n8n_worker_pools_chart_verified n8n_worker_keda_min_replicas n8n_worker_keda_max_replicas" ;;
    *) echo "" ;;
  esac
}

status=0

base_vars="$(variable_names "${EXAMPLES_DIR}/${BASE_EXAMPLE}/variables.tf")"

for dir in "${EXAMPLES_DIR}"/*/; do
  example="$(basename "$dir")"
  [ "$example" = "$BASE_EXAMPLE" ] && continue
  [ -f "${dir}variables.tf" ] || continue

  example_vars="$(variable_names "${dir}variables.tf")"

  missing="$(comm -23 <(echo "$base_vars") <(echo "$example_vars"))"
  extra="$(comm -13 <(echo "$base_vars") <(echo "$example_vars"))"

  allowed_missing="$(missing_ok "$example")"
  allowed_extra="$(extra_ok "$example")"

  unexpected_missing=""
  for name in $missing; do
    [ -z "$name" ] && continue
    if ! [[ " $allowed_missing " == *" $name "* ]]; then
      unexpected_missing="$unexpected_missing $name"
    fi
  done

  unexpected_extra=""
  for name in $extra; do
    [ -z "$name" ] && continue
    if ! [[ " $allowed_extra " == *" $name "* ]]; then
      unexpected_extra="$unexpected_extra $name"
    fi
  done

  if [ -n "$unexpected_missing" ]; then
    echo "FAIL: examples/${example} is missing (vs examples/${BASE_EXAMPLE}, not in its allowlist):${unexpected_missing}" >&2
    status=1
  fi
  if [ -n "$unexpected_extra" ]; then
    echo "FAIL: examples/${example} declares (not in examples/${BASE_EXAMPLE}, not in its allowlist):${unexpected_extra}" >&2
    status=1
  fi

  # A stale allowlist entry naming a variable that no longer actually
  # differs is itself a failure, so the allowlist cannot silently rot.
  missing_joined=" $(echo "$missing" | tr '\n' ' ') "
  extra_joined=" $(echo "$extra" | tr '\n' ' ') "
  for name in $allowed_missing; do
    if ! [[ "$missing_joined" == *" $name "* ]]; then
      echo "FAIL: examples/${example}'s missing_ok allowlist names '${name}', but it is not actually missing (present in both, or in neither and never was) - remove the stale entry" >&2
      status=1
    fi
  done
  for name in $allowed_extra; do
    if ! [[ "$extra_joined" == *" $name "* ]]; then
      echo "FAIL: examples/${example}'s extra_ok allowlist names '${name}', but it is not actually extra - remove the stale entry" >&2
      status=1
    fi
  done
done

for example in "${REQUIRE_PRODUCTION_CONSIDERATIONS[@]}"; do
  readme="${EXAMPLES_DIR}/${example}/README.md"
  if [ ! -f "$readme" ]; then
    echo "FAIL: ${readme} does not exist" >&2
    status=1
    continue
  fi
  if ! python3 -c "
import sys
with open(sys.argv[1]) as f:
    text = f.read()
sys.exit(0 if '## Production considerations' in text else 1)
" "$readme"; then
    echo "FAIL: ${readme} has no '## Production considerations' section, but this example lets the module own Cloud SQL and/or GCS" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "check-example-parity.sh: every example matches examples/${BASE_EXAMPLE}'s variable set within its own allowlist, and every Cloud-SQL/GCS-owning example documents Production considerations"
