# ── GoDaddy DNS ───────────────────────────────────────────────────────────────
# A-record: n8n_domain -> the module's LB static IP. Once this resolves, the
# module's Google-managed certificate provisions automatically.
#
# The record name is the host portion of n8n_domain relative to godaddy_domain
# (e.g. n8n_domain "n8n.example.com" in zone "example.com" -> name "n8n").

resource "godaddy-dns_record" "n8n" {
  domain = var.godaddy_domain
  name   = trimsuffix(var.n8n_domain, ".${var.godaddy_domain}")
  type   = "A"
  data   = module.n8n.static_ip
  ttl    = 600
}
