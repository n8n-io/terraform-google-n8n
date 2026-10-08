# Fixture for the second, opt-in checkov pass (tests/scripts/check-checkov.sh
# and the CI checkov job's "checkov (opt-in)" step). Every module resource
# gated by a switch that defaults false plans at count 0 under the default
# tfvars, so checkov answers every one of its checks on that resource
# UNKNOWN and drops it from the report; this fixture flips those switches on
# so the resources actually get scanned. See AGENTS.md, "Static analysis",
# for the corrected diagnosis this fixture exists to keep from reopening.
#
# Add a new switch here whenever a new count-gated resource is introduced;
# check-checkov.sh fails if the opt-in pass does not reach it.

friendly_name_prefix   = "checkov-optin"
project_id             = "checkov-optin-project"
n8n_fqdn               = "n8n.checkov-optin.example.com"
n8n_license_key        = "checkov-fixture-not-a-real-license-key"
redis_exporter_enabled = true

# GKE application-layer secrets encryption: unblinds google_kms_crypto_key.gke
# and google_kms_crypto_key_iam_member.gke (kms.tf). A module-created key
# needs a key ring reference, so the fixture also creates the shared ring.
create_kms_key_ring = true
create_gke_kms_key  = true
