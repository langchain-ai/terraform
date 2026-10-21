# Runbook: migrate LangSmith TLS to a Google-managed certificate on a GKE Gateway

## Purpose

Move TLS for `langsmith.their-domain.com` from the in-cluster certificate that Envoy Gateway serves today to a Google-managed certificate served by a GKE Gateway. The Google-managed certificate is issued and renewed by Google Certificate Manager using DNS authorization, and the cutover is a blue/green DNS switch with a clean rollback.

## Audience

Your platform or infrastructure team, running the self-hosted LangSmith GCP deployment on GKE with access to the GCP project, the cluster, and the `their-domain.com` DNS zone.

## Scope

In scope: issuing the Google-managed certificate, standing up a parallel GKE Gateway, validating it before any user traffic moves, cutting over by DNS, and decommissioning the old Envoy TLS path.

Out of scope, and unchanged by this procedure:

- The GoDaddy-issued `*.their-domain.com` wildcard certificate. It stays exactly where it is and keeps serving every other use. This migration never cancels or replaces it. Every CAA change below is additive.
- Application configuration, database, and storage. Only the ingress and certificate path change.
- Any hostname other than `langsmith.their-domain.com`.

## Current state

- Ingress is Envoy Gateway using the Kubernetes Gateway API. TLS terminates in the cluster from the Kubernetes Secret `langsmith-tls`, which holds your GoDaddy wildcard certificate (the `existing` certificate source in the module, not Let's Encrypt).
- The public entry point is an L4 load balancer fronting the Envoy proxy Service. It is not a GCP L7 HTTPS proxy, so there is no Google-managed certificate in the current path.
- The LangSmith Helm chart owns the HTTPRoute that binds the hostname to the `frontend` Service on port 80. Terraform owns the Envoy Gateway itself.

## Target state

- A GKE Gateway (`GatewayClass: gke-l7-global-external-managed`) serves `langsmith.their-domain.com` on a new global external IP.
- A Google-managed certificate is attached to that Gateway through a Certificate Manager certificate map, referenced by the `networking.gke.io/certmap` annotation. The HTTPS listener carries no `tls` block, because the certificate map supplies the certificate.
- The certificate renews automatically before expiry with no redeploy, as long as the DNS authorization record stays in place.

## How two certificate authorities coexist for one domain

You will have two certificates for names under `their-domain.com` at the same time, from two different authorities, and that is fine:

- The GoDaddy wildcard (issued by GoDaddy / Starfield) keeps serving `*.their-domain.com` wherever you already use it.
- The Google-managed certificate covers only `langsmith.their-domain.com` and is issued by Google Trust Services (with Let's Encrypt as a fallback).

A TLS certificate is scoped to the names inside it, not to the whole domain, and nothing binds a domain to a single issuer. The only domain-wide control is CAA (see [Handle CAA](#step-3-handle-caa-only-if-caa-records-exist)), and CAA is an allowlist you extend, not a switch you flip. Each endpoint presents whichever certificate its own load balancer is configured to serve, so the wildcard and the Google-managed certificate operate independently.

## Prerequisites

Confirm every item before you start. Several of these are correctness gates, not conveniences.

1. Confirm the current certificate source is `existing` (the GoDaddy wildcard loaded into `langsmith-tls`). If your deployment instead stood up Let's Encrypt, stop and revise this runbook, because the decommission step differs.
2. The cluster is VPC-native (alias IP) and has the HTTP load balancing add-on enabled. Both are required for GKE Gateway.
3. The project uses the Premium Network Tier. The global external Application Load Balancer class used here requires it.
4. Certificate Manager API is enabled: `gcloud services enable certificatemanager.googleapis.com`. (The GCP module already enables it.)
5. You can edit the `their-domain.com` DNS zone: add a CNAME, add CAA records, and later change the `langsmith` A and AAAA records.
6. Confirm the cluster is not on GKE `1.28.4-gke.1083000`. That build has a known defect serving Certificate Manager certificates on Gateways. Check with `gcloud container clusters describe <cluster> --location <location> --format="value(currentMasterVersion)"` and upgrade off it if needed.

### The one prerequisite that can disrupt the live path

Enabling the Gateway API on a cluster that is already running Envoy Gateway is not guaranteed to be a no-op. Envoy Gateway installed its own Gateway API CRDs (v1.4.1). GKE, once you enable the Gateway API at the Standard channel, installs and manages those same CRDs cluster-wide. They can collide on version or ownership, and the CRDs are what your currently serving Envoy path depends on.

Reduce the risk before you touch the production cluster:

- Test the enable step in a non-production cluster first, and watch the existing Envoy Gateway keep serving through it.
- Make sure the Envoy Gateway Helm release does not reinstall or overwrite the CRDs. Install or upgrade it with `crds.gatewayAPI.enabled=false` (or `crds.enabled=false`) so GKE owns the Gateway API CRDs.

Treat this as the highest-risk step in the migration, not a routine prerequisite.

## Step 1: Enable the Gateway API on the cluster

After the CRD check above, enable the Gateway API at the Standard channel:

```bash
gcloud container clusters update <cluster> \
  --location <location> \
  --gateway-api=standard
```

Reconciliation can take up to 45 minutes. Confirm the GKE GatewayClasses appear:

```bash
kubectl get gatewayclass
```

Pass criteria: the list includes `gke-l7-global-external-managed`.

## Step 2: Issue the Google-managed certificate

### Create the DNS authorization

```bash
gcloud certificate-manager dns-authorizations create langsmith-dns-auth \
  --domain="langsmith.their-domain.com"
```

Read back the CNAME record you need to publish:

```bash
gcloud certificate-manager dns-authorizations describe langsmith-dns-auth
```

Add the CNAME exactly as shown in the output. Its name is under `_acme-challenge.langsmith.their-domain.com` and its target is a `*.authorize.certificatemanager.goog` host.

Two rules for this record:

- It must be the only record at that name. Do not add any other record (TXT or otherwise) alongside it.
- It must stay published permanently. Certificate Manager re-checks it at every renewal; removing it breaks renewal.

### Create the certificate

```bash
gcloud certificate-manager certificates create langsmith-cert \
  --domains="langsmith.their-domain.com" \
  --dns-authorizations=langsmith-dns-auth
```

### Create the certificate map and entry

```bash
gcloud certificate-manager maps create langsmith-cert-map

gcloud certificate-manager maps entries create langsmith-cert-map-entry \
  --map="langsmith-cert-map" \
  --certificates="langsmith-cert" \
  --hostname="langsmith.their-domain.com"
```

### Wait for the certificate to go active

```bash
gcloud certificate-manager certificates describe langsmith-cert
```

Pass criteria: the DNS authorization state is `AUTHORIZED` and the certificate state is `ACTIVE`. This can take from a few minutes to about an hour after the CNAME propagates. Do not proceed to the DNS cutover until the certificate is `ACTIVE`.

## Step 3: Handle CAA (only if CAA records exist)

Check for existing CAA records:

```bash
dig CAA their-domain.com +short
dig CAA langsmith.their-domain.com +short
```

If both return nothing, no CAA change is needed. With no CAA records, any public CA may issue, and issuance already succeeded in Step 2. Adding CAA is good hygiene but not required.

If CAA records exist, they must permit the Google-managed issuer without removing GoDaddy's. Add these entries alongside the existing ones (keep every current GoDaddy / Starfield entry):

```dns
their-domain.com. CAA 0 issue "pki.goog"
their-domain.com. CAA 0 issue "letsencrypt.org"
```

Google Trust Services (`pki.goog`) issues by default, and Let's Encrypt (`letsencrypt.org`) is the fallback, so both belong. If you prefer to allow only `pki.goog`, create the DNS authorization with `--type=PER_PROJECT_RECORD` instead, which pins issuance to Google Trust Services.

## Step 4: Stand up the GKE Gateway (blue side)

This runs in parallel with the live Envoy path and gets its own new IP. No user traffic moves yet.

Confirm the backend Service name and port first. The target is the LangSmith `frontend` Service on port 80, the same backend the chart's Envoy HTTPRoute serves. The Service name follows your Helm release name, for example `<release>-frontend`:

```bash
kubectl get httproute -n <langsmith-namespace> -o yaml   # shows the current backendRef
kubectl get svc -n <langsmith-namespace> | grep frontend
```

Create the Gateway. Note there is no `tls` block on the listener, because the certificate map supplies the certificate, and the two are mutually exclusive:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: langsmith-gke-gateway
  namespace: <langsmith-namespace>
  annotations:
    networking.gke.io/certmap: langsmith-cert-map
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "langsmith.their-domain.com"
      allowedRoutes:
        namespaces:
          from: Same
```

Create an HTTPRoute that binds the hostname to the frontend Service. This is separate from the chart-managed HTTPRoute on the Envoy Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: langsmith-gke-route
  namespace: <langsmith-namespace>
spec:
  parentRefs:
    - name: langsmith-gke-gateway
  hostnames:
    - "langsmith.their-domain.com"
  rules:
    - backendRefs:
        - name: <release>-frontend
          port: 80
```

Read the new global IP once the Gateway programs:

```bash
kubectl get gateways.gateway.networking.k8s.io langsmith-gke-gateway \
  -n <langsmith-namespace> \
  -o=jsonpath="{.status.addresses[0].value}"
```

### Backend health check

The GKE Gateway derives a health check for the backend Service. If the check fails, the load balancer returns 502 even when TLS is correct. The `frontend` Service serves nginx on port 80 and answers `/`, which the default check normally satisfies. If Step 5 returns 502, attach a `HealthCheckPolicy` targeting the path and port the frontend actually serves.

## Step 5: Validate the blue side before cutover

Test the new Gateway directly, without changing any DNS, by pinning the hostname to the new IP:

```bash
curl -v --resolve langsmith.their-domain.com:443:<NEW_GATEWAY_IP> \
  https://langsmith.their-domain.com/
```

Pass criteria, all four:

- The TLS handshake succeeds.
- The served certificate's issuer is Google Trust Services (or Let's Encrypt), not GoDaddy / Starfield. This confirms you are hitting the new managed certificate, not the wildcard.
- The certificate's subject or SAN is `langsmith.their-domain.com`.
- The application responds (HTTP 200 on a known path), not 502.

Allow about 10 minutes after the certificate map attaches for the load balancer to serve the certificate everywhere. Do not cut over until all four pass.

## Step 6: Cut over by DNS (green)

1. Ahead of time, lower the TTL on the `langsmith` A and AAAA records (for example to 60 seconds) so a rollback propagates fast.
2. Change the `langsmith.their-domain.com` A and AAAA records from the Envoy L4 IP to `<NEW_GATEWAY_IP>`.
3. Leave the Envoy path running and untouched.
4. Watch traffic shift to the new load balancer and monitor error rates.

## Step 7: Validate after cutover

```bash
curl -v https://langsmith.their-domain.com/
```

Confirm the same four pass criteria from Step 5 against real DNS, ideally from more than one resolver, and confirm application logs show healthy traffic on the new load balancer.

## Rollback

Rollback is a DNS change, because nothing on the Envoy path was modified:

- Change the `langsmith` A and AAAA records back to the Envoy L4 IP. The low TTL from Step 6 makes this fast.
- Traffic returns to the Envoy path, which was serving the whole time.

## Decommission the Envoy TLS path

Only after the new path has run clean through a soak period you are comfortable with:

1. Remove the chart-managed HTTPRoute binding and the Envoy Gateway from your configuration.
2. When uninstalling or scaling down Envoy Gateway, make sure its Helm release does not delete the Gateway API CRDs, which GKE now depends on. Confirm the CRDs remain and are owned by GKE.
3. The `langsmith-tls` Secret and the GoDaddy wildcard stay in place if anything else uses them. This migration never removes them.

## Renewal

The Google-managed certificate is a 90-day domain-validated certificate. Certificate Manager renews it automatically before expiry, and the load balancer picks up the new certificate from the certificate map with no redeploy and no operator action. Renewal depends on two things staying in place: the `_acme-challenge` CNAME from Step 2 and the DNS authorization. Do not remove either.

## Failure modes and caveats

- Gateway API CRD collision with Envoy (highest risk). Enabling the cluster Gateway API while Envoy Gateway is running can conflict over the shared CRDs. Test in non-production first and keep Envoy from managing the CRDs (`crds.gatewayAPI.enabled=false`).
- Cutover before the certificate is active. The certificate must reach `ACTIVE` and the map entry must attach before any DNS change, with about 10 minutes of slack for the load balancer to serve it.
- DNS-01 only. Certificate Manager authorizes through the DNS CNAME. There is no HTTP-01 path here; do not carry over any HTTP-01 configuration from the Envoy setup.
- Stray record at `_acme-challenge`. The authorization CNAME must be the only record at that name, and it must persist for renewal.
- CAA fallback trap. If CAA records exist and list only `pki.goog`, a fallback to Let's Encrypt is blocked. Include `letsencrypt.org` too, or pin issuance to Google Trust Services with `PER_PROJECT_RECORD`.
- Wrong Gateway class. The `networking.gke.io/certmap` annotation attaches the certificate on the global external class only. The regional class uses a different mechanism (`networking.gke.io/cert-manager-certs` and a proxy-only subnet), so do not mix them.
- Backend 502s. A GKE Gateway needs a healthy backend. If the frontend is not healthy on the checked path, TLS succeeds but requests return 502. Confirm with the Step 5 test before cutover.
- Known GKE version defect. Avoid `1.28.4-gke.1083000` for Certificate Manager certificates on Gateways.

## Codifying in terraform

The commands above prove the path quickly and are safe to run by hand. Once validated, codify the certificate resources to avoid drift: `google_certificate_manager_dns_authorization`, `google_certificate_manager_certificate` (managed, with `domains` and `dns_authorizations`), `google_certificate_manager_certificate_map`, and `google_certificate_manager_certificate_map_entry` (keyed by hostname), plus the Gateway and HTTPRoute manifests. The current GCP module does not yet expose a `google-managed` certificate source, so these are additions to your configuration.
