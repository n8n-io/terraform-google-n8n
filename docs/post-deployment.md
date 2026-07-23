# Post-deployment setup

After `terraform apply` completes, finish setup by pointing your domain at n8n and activating your n8n Enterprise license.

## Wait for the load balancer and certificate

The Google Cloud L7 load balancer is provisioned asynchronously after the Ingress resource is created. Allow a few minutes after apply for it to become reachable, and, with `tls_mode = "google_managed"`, a further few minutes for the ManagedCertificate to move to `Active`. Verify:

```bash
terraform refresh
terraform output -raw static_ip
kubectl get ingress n8n-ingress -n n8n
kubectl get managedcertificate -n n8n   # only for tls_mode = "google_managed"
```

## Point your domain at n8n

**If you used `cloud_dns_zone_name`:** nothing to do, the A-record was created during apply. Verify propagation:

```bash
dig +short n8n.yourdomain.com
```

**If you manage DNS yourself:** create an A-record pointing at the load balancer IP.

| Type | Name                      | Value                                      | TTL |
| ---- | ------------------------- | ------------------------------------------ | --- |
| A    | `n8n` (or your subdomain) | IP from `terraform output -raw static_ip`  | 300 |

With `tls_mode = "google_managed"`, the certificate cannot provision until this record resolves to the load balancer IP, so create it promptly after apply.

## Access n8n and activate your license

Open `https://n8n.yourdomain.com` in your browser. Create your owner account, then select **Settings** > **License** and enter your activation key.
