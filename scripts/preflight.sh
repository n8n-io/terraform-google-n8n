#!/usr/bin/env bash
#
# Preflight: check that the ACTIVE gcloud identity can actually deploy this
# module into a project, BEFORE `terraform apply` finds out the hard way.
#
# It changes nothing. It uses the Resource Manager testIamPermissions REST API
# (reports your effective permissions), checks required API enablement, and
# reports the current effective state of the iam.disableServiceAccountKeyCreation
# org policy (the usual blocker for the GCS HMAC key).
#
# Requires: gcloud (authenticated), curl, python3.
#
# Usage:
#   ./preflight.sh PROJECT_ID
#   ./preflight.sh                     # uses `gcloud config get-value project`
#
# Env toggles (match the module's optional paths):
#   CHECK_ORG_POLICY=true|false   # default true  (manage_sa_key_org_policy path)
#   CHECK_CLOUD_DNS=true|false    # default false (dns_managed_zone path; off for the Cloudflare example)
#
# Exit: 0 = all required checks pass; 1 = a required API/permission is missing;
#       2 = usage / no auth. Org-policy-override rights are reported as WARNING
#       (you can disable the policy out-of-band instead), never a hard failure.

set -uo pipefail

PROJECT="${1:-$(gcloud config get-value project 2>/dev/null)}"
CHECK_ORG_POLICY="${CHECK_ORG_POLICY:-true}"
CHECK_CLOUD_DNS="${CHECK_CLOUD_DNS:-false}"

if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "usage: $0 PROJECT_ID   (or run: gcloud config set project PROJECT_ID)" >&2
  exit 2
fi

ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
if [[ -z "${ACCOUNT}" || -z "${TOKEN}" ]]; then
  echo "No active gcloud credentials. Run: gcloud auth login" >&2
  exit 2
fi

echo "Account : ${ACCOUNT}"
echo "Project : ${PROJECT}"
echo "Paths   : org-policy=${CHECK_ORG_POLICY}  cloud-dns=${CHECK_CLOUD_DNS}"
echo

fail=0
warn=0

# ── Required APIs ─────────────────────────────────────────────────────────────
# Core APIs are hard-required. orgpolicy is only needed for the override path, so
# it is handled (softly) in the org-policy section, not here.
apis=(container.googleapis.com sqladmin.googleapis.com redis.googleapis.com \
      servicenetworking.googleapis.com compute.googleapis.com iam.googleapis.com)
[[ "${CHECK_CLOUD_DNS}" == "true" ]] && apis+=(dns.googleapis.com)

enabled="$(gcloud services list --enabled --project="${PROJECT}" --format='value(config.name)' 2>/dev/null)"

echo "== APIs enabled =="
if [[ -z "${enabled}" ]]; then
  echo "  [warn] could not list enabled services (need serviceusage.services.list)"
  warn=1
fi
for api in "${apis[@]}"; do
  if grep -qxF "${api}" <<<"${enabled}"; then
    echo "  [ok]   ${api}"
  else
    echo "  [MISS] ${api}   -> gcloud services enable ${api} --project=${PROJECT}"
    fail=1
  fi
done
echo

# ── IAM permissions (Resource Manager testIamPermissions REST API) ────────────
# gcloud has no `projects test-iam-permissions` subcommand, so call the REST
# endpoint directly. Returns only the granted subset of the queried permissions.
query_granted() {
  local perms_json body
  perms_json="$(printf '"%s",' "$@")"
  perms_json="[${perms_json%,}]"
  body="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "{\"permissions\": ${perms_json}}" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}:testIamPermissions")"
  printf '%s' "${body}" | python3 -c 'import sys, json
try:
    print("\n".join(json.load(sys.stdin).get("permissions", [])))
except Exception:
    pass' 2>/dev/null
}

perms=(
  compute.networks.create compute.subnetworks.create compute.routers.create
  compute.globalAddresses.create compute.sslCertificates.create
  servicenetworking.services.addPeering
  container.clusters.create container.clusters.get
  cloudsql.instances.create
  redis.instances.create
  storage.buckets.create storage.hmacKeys.create
  iam.serviceAccounts.create iam.serviceAccounts.setIamPolicy
  resourcemanager.projects.setIamPolicy
  serviceusage.services.enable
)
[[ "${CHECK_CLOUD_DNS}" == "true" ]] && perms+=(dns.managedZones.get dns.changes.create)

granted="$(query_granted "${perms[@]}")"

echo "== IAM permissions (module core) =="
if [[ -z "${granted}" ]]; then
  echo "  [warn] testIamPermissions returned nothing, either you hold none of these,"
  echo "         or the call failed. Raw check:"
  echo "         curl -s -X POST -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
  echo "           -d '{\"permissions\":[\"storage.buckets.create\"]}' \\"
  echo "           https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}:testIamPermissions"
fi
for p in "${perms[@]}"; do
  if grep -qxF "${p}" <<<"${granted}"; then
    echo "  [ok]   ${p}"
  else
    echo "  [MISS] ${p}"
    fail=1
  fi
done
echo

# ── Org policy: iam.disableServiceAccountKeyCreation (the HMAC blocker) ────────
if [[ "${CHECK_ORG_POLICY}" == "true" ]]; then
  echo "== Org policy: iam.disableServiceAccountKeyCreation =="
  if grep -qxF "orgpolicy.googleapis.com" <<<"${enabled}"; then
    # v2 (orgpolicy API) gives the EFFECTIVE value including org/folder inheritance.
    eff="$(gcloud org-policies describe iam.disableServiceAccountKeyCreation \
            --project="${PROJECT}" --effective --quiet \
            --format='value(spec.rules[0].enforce)' </dev/null 2>/dev/null || echo "ERR")"
    effective="true"
  else
    # v1 (Resource Manager) works WITHOUT the orgpolicy API, but only reads the
    # policy set AT this project, not org/folder inheritance.
    v1="$(gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
           --project="${PROJECT}" --format='value(booleanPolicy.enforced)' </dev/null 2>/dev/null || echo "ERR")"
    case "${v1}" in
      True|TRUE) eff="TRUE" ;;
      ERR)       eff="ERR" ;;
      *)         eff="" ;;
    esac
    effective="false"
  fi

  case "${eff}" in
    TRUE)
      echo "  [BLOCK] enforced -> HMAC key creation is blocked."
      if grep -qxF "orgpolicy.policy.set" <<<"$(query_granted orgpolicy.policy.set)"; then
        echo "          You HAVE orgpolicy.policy.set: set manage_sa_key_org_policy = true, or disable out-of-band."
      else
        echo "  [warn]  You lack orgpolicy.policy.set: an org/folder admin must disable it;"
        echo "          manage_sa_key_org_policy = true would FAIL for you."
        warn=1
      fi
      ;;
    FALSE|"")
      if [[ "${effective}" == "true" ]]; then
        echo "  [ok]    not enforced (effective) -> HMAC key creation is allowed. Leave manage_sa_key_org_policy = false."
      else
        echo "  [ok?]   no enforcement set at the PROJECT level -> likely allowed."
        echo "  [warn]  could not check org/folder INHERITANCE (orgpolicy API off). For a definitive"
        echo "          effective read: gcloud services enable orgpolicy.googleapis.com --project=${PROJECT} && re-run."
        warn=1
      fi
      ;;
    *)
      echo "  [warn]  could not read the policy (need orgpolicy.policy.get). Check manually:"
      echo "          gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation --project=${PROJECT}"
      warn=1
      ;;
  esac
  echo
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ "${fail}" -ne 0 ]]; then
  echo "RESULT: FAIL, missing required APIs/permissions above. Fix before terraform apply."
  exit 1
elif [[ "${warn}" -ne 0 ]]; then
  echo "RESULT: PASS with warnings, review the [warn]/[BLOCK] lines above."
  exit 0
else
  echo "RESULT: PASS, this identity can deploy the module into ${PROJECT}."
  exit 0
fi
