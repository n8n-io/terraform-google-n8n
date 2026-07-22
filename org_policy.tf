# ── Org policy override (opt-in) ──────────────────────────────────────────────
# The GCS HMAC key (gcs.tf) that n8n's S3-compatible driver needs is blocked by
# the iam.disableServiceAccountKeyCreation org policy. When
# manage_sa_key_org_policy = true, set a PROJECT-LEVEL override that turns the
# constraint off for this project.
#
# WARNING: this requires roles/orgpolicy.policyAdmin (org/folder-level) and
# overrides a security guardrail. Default is off; see the variable description.
# When left off, disable the policy out-of-band before applying.

resource "google_org_policy_policy" "disable_sa_key_creation" {
  count = var.manage_sa_key_org_policy ? 1 : 0

  name   = "projects/${var.project_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "FALSE"
    }
  }
}
