# TLS on GCP

This page covers the certificate for the LangSmith hostname: where it comes
from, which Gateway serves it, and how to move between options. TLS to Cloud SQL,
Memorystore, and ClickHouse is configured separately.

## Choose a certificate source

`tls_certificate_source` picks one. Every source except `none` gives the
Gateway an HTTPS listener and makes its HTTP listener redirect to HTTPS
(301).

| Source | Where the certificate lives | Gateway | Use it for |
|---|---|---|---|
| `google-managed` | Certificate Manager, on the Google Cloud load balancer | GKE Gateway (`ingress_type = "gke"`), global class | Production on GKE Gateway. No key in the cluster, no cert-manager, no inbound port 80 |
| `existing` | A Kubernetes TLS Secret you create | Envoy or GKE | Production with a certificate from your own PKI |
| `cert-manager` | A Secret that cert-manager writes, from your own Issuer | Envoy or GKE | Production with automated renewal from Vault, Venafi, Google CAS, or a private ACME server |
| `none` | — | Envoy or GKE | HTTP only |

## google-managed

A Google-managed certificate from
[Certificate Manager](https://cloud.google.com/certificate-manager/docs/overview),
attached to the GKE Gateway through a certificate map. Google renews it.

```hcl
ingress_type           = "gke"
gke_gateway_class      = "gke-l7-global-external-managed"   # the default
tls_certificate_source = "google-managed"
langsmith_domain       = "langsmith.example.com"

# Optional
# tls_google_managed_include_wildcard = true   # also cover *.langsmith.example.com
# tls_google_managed_issuance_config  = "projects/<p>/locations/global/certificateIssuanceConfigs/<name>"
```

`terraform apply` creates a DNS authorization, the certificate, a certificate
map, and a `PRIMARY` map entry, then sets `networking.gke.io/certmap` on the
Gateway. The HTTPS listener carries no `certificateRefs`: GKE rejects a Gateway
that has both.

### Prove control of the domain

Certificate Manager issues the certificate after it sees a CNAME record that
proves you control the domain. The record does not depend on where the domain
points, so the certificate can be issued before DNS points at the Gateway, and
the first deploy can be HTTPS.

- With `enable_dns_module = true`, Terraform writes the record into the module's
  Cloud DNS zone (`tls_dns_authorization_record_managed = true`).
- Otherwise add it at your DNS provider:

  ```bash
  terraform -chdir=infra output tls_dns_authorization_record
  # { name = "_acme-challenge.langsmith.example.com.", type = "CNAME", data = "....authorize.certificatemanager.goog." }
  ```

Then point `langsmith_domain` at the Gateway address
(`terraform -chdir=infra output -raw ingress_ip`). Check progress with
`make status`, or:

```bash
gcloud certificate-manager certificates describe "$(terraform -chdir=infra output -raw managed_certificate_name)" \
  --project <project> --format='value(managed.state)'
```

`PROVISIONING` usually turns `ACTIVE` within minutes to an hour of the record
resolving. If the domain has CAA records, they must allow `pki.goog`.

### After the first deploy

- When the Gateway first reports `Programmed`, the global load balancer still
  needs a few minutes to reach every Google edge location. Until then, an HTTPS
  request can reset, or return `404` with the body `fault filter abort`. Until
  the LangSmith backends pass their health checks, it returns `502`. See
  TROUBLESHOOTING.md, Issue #6d.
- To test before DNS points at the Gateway, send the domain to the Gateway
  address:

  ```bash
  IP=$(terraform -chdir=infra output -raw ingress_ip)
  curl --resolve "langsmith.example.com:443:$IP" https://langsmith.example.com/api/v1/ok
  ```

- GKE writes the redirect `Location` header with the port, for example
  `https://langsmith.example.com:443/`. Browsers treat it as the same URL.
- A change of `langsmith_domain` or `tls_google_managed_include_wildcard`
  replaces the certificate, and HTTPS fails until the new certificate is
  `ACTIVE`. A new domain also gets a new DNS authorization record. Add that
  record as soon as `terraform apply` shows it.

### Private CA

Set `tls_google_managed_issuance_config` to a Certificate Manager issuance
config that points at your Certificate Authority Service pool. The certificate
is then issued by your CA, and no DNS authorization is created. Clients must
trust your CA.

### Limits

- The GKE Gateway supports only the global class `gke-l7-global-external-managed`.
  A regional class, such as the internal `gke-l7-rilb`, needs a proxy-only
  subnet and a regional certificate, which this module does not create yet.
  Terraform rejects other classes at plan time.
- Envoy Gateway terminates TLS in the cluster behind a passthrough load
  balancer, so it cannot use a Google-managed certificate. Use `existing` or
  `cert-manager` with Envoy.

## existing

Your own certificate in a `kubernetes.io/tls` Secret in the LangSmith
namespace. Create the Secret yourself, by hand or with External Secrets, and
name it. Terraform only references it, so the private key never enters
Terraform state.

```hcl
tls_certificate_source   = "existing"
tls_existing_secret_name = "langsmith-tls"
```

```bash
kubectl create secret tls langsmith-tls -n langsmith --cert=tls.crt --key=tls.key
```

Rotate by updating the Secret. The Gateway controller watches it, so no restart
is needed.

`tls_certificate_crt` and `tls_certificate_key` still work: Terraform writes them
to a Secret named `tls_secret_name`. They are deprecated because the key is
then stored in Terraform state, and the plan warns when they are set. Set one
approach or the other, not both.

With Envoy Gateway, Terraform also creates a ReferenceGrant so the Gateway in
`envoy-gateway-system` can read the Secret in the LangSmith namespace. Earlier
versions created it only for Let's Encrypt.

## cert-manager with your own issuer

Terraform installs cert-manager and creates a `Certificate` for
`langsmith_domain` that writes `tls_secret_name`. You create the issuer.

```hcl
tls_certificate_source   = "cert-manager"
cert_manager_issuer_name = "corp-pki"
cert_manager_issuer_kind = "ClusterIssuer"   # or "Issuer" in the LangSmith namespace
```

The issuer must be able to issue without an HTTP-01 challenge on this Gateway:
a CA, Vault, or Venafi issuer, Google CAS through the
[google-cas-issuer](https://github.com/jetstack/google-cas-issuer), or ACME with
DNS-01. Terraform does not route HTTP-01 challenges to the Gateway.

## HTTP to HTTPS redirect

With TLS on, the ingress module creates the HTTPRoute
`<gateway>-https-redirect` on the Gateway's `http` listener, which answers every
request with a 301 to the same URL over HTTPS. `make init-values` sets
`gateway.sectionName: "https"` so the LangSmith HTTPRoute attaches only to the
HTTPS listener.

The chart does not pass a section name to the Deployments operator, so the
HTTPRoutes it creates for LangSmith Deployments attach to both listeners. A route
with a more specific match than the redirect's `/` prefix still answers plain
HTTP on its paths, as before this change.

## cert-manager version

The module installs cert-manager **v1.21.2** (`cert_manager_version`) from the
OCI chart `oci://quay.io/jetstack/charts/cert-manager`. Earlier module versions
installed v1.14.4, which has been out of support since 2024.

cert-manager supports upgrades one minor version at a time. Before Helm runs,
`terraform apply` checks the installed version and stops when it is more than
one minor behind `cert_manager_version`. To step an existing install up:

```bash
make cert-manager-upgrade   # v1.14.4 -> 1.15.5 -> 1.16.5 -> 1.17.4 -> 1.18.6 -> 1.19.6 -> 1.20.4 -> 1.21.2
make apply                  # puts the release back under Terraform's values and the OCI repository
```

The script asks before it starts (`YES=1` skips the prompt), waits for
cert-manager to be ready after each step, and lists any Certificate that is not
Ready at the end. Certificates, Issuers, and their Secrets stay in place.

Read the [upgrade notes](https://cert-manager.io/docs/releases/upgrading/) for
each step. The ones most likely to matter here:

- 1.15: the `startupapicheck` Job uses its own image. Mirror it if you pull
  images through a registry mirror.
- 1.16: the chart validates values against a schema and rejects unknown keys.
- 1.18: the default private key `rotationPolicy` changes from `Never` to
  `Always`, so renewed certificates get a new key.
- 1.19.0 can re-issue certificates unnecessarily. The script uses 1.19.6.
- 1.21: the chart no longer creates the Role that let the controller create
  tokens for its own ServiceAccount. Only issuers that use
  `serviceAccountRef.name` with the controller's ServiceAccount need it.

## Upgrading from an earlier module version

- **`letsencrypt`**: removed. See [Moving off Let's Encrypt](#moving-off-lets-encrypt).
- **cert-manager installed** (`cert-manager`, or `install_cert_manager = true`):
  run `make cert-manager-upgrade` before `make apply`, or the apply stops at the
  version check.
- **`dns_create_certificate`**: the DNS module no longer creates a classic
  Google-managed SSL certificate. Nothing in the module attached it. Terraform
  forgets it without deleting it (a `removed` block). Delete it with
  `gcloud compute ssl-certificates delete <name-prefix>-<environment>-langsmith`
  once nothing uses it, and remove `dns_create_certificate` from
  `terraform.tfvars`.
- **`existing` with PEM inputs**: still works, with a plan warning. To move the
  key out of state, create the Secret yourself, set `tls_existing_secret_name`,
  and remove `tls_certificate_crt` and `tls_certificate_key`. Terraform then
  deletes the Secret it created, so give yours a different name, or create it
  after the apply.
- **Redirect**: run `make init-values` and `make deploy` after `make apply`, so
  the LangSmith HTTPRoute moves to the HTTPS listener. Until then HTTP keeps
  serving LangSmith instead of redirecting.

## Moving off Let's Encrypt

Earlier module versions had `tls_certificate_source = "letsencrypt"`. This
version removes it, and a plan that still sets it stops at the variable check.
Those versions installed cert-manager v1.14.4 without Gateway API support, which
the HTTP-01 solver on the Envoy Gateway needs, so check whether your certificate
was ever issued: `kubectl get certificate -n langsmith`.

Pick one of these:

- **google-managed** (recommended): set `tls_certificate_source = "google-managed"`
  on the GKE Gateway (`ingress_type = "gke"`). The GKE Gateway gets a new IP
  address. Apply, add the DNS authorization record, and wait for `ACTIVE`. Then
  move the domain's A record to `terraform -chdir=infra output -raw ingress_ip`.
- **existing**: keep the Secret that cert-manager wrote. Set
  `tls_certificate_source = "existing"` and set `tls_existing_secret_name` to
  your `tls_secret_name` (default `langsmith-tls`). Nothing renews the
  certificate after that. Replace the Secret before the certificate expires.
- **cert-manager with your own ACME issuer**: to keep Let's Encrypt, create a
  ClusterIssuer with a DNS-01 solver, for example for Cloud DNS. Set
  `tls_certificate_source = "cert-manager"` and `cert_manager_issuer_name`.
  Terraform creates the Certificate for that issuer.

Then remove `letsencrypt_email` from `terraform.tfvars`. Until you do, Terraform
warns about an undeclared variable.

Terraform does not delete the `letsencrypt-prod` ClusterIssuer or the
Certificate that it created before. With `google-managed` or `existing`, it
uninstalls cert-manager unless `install_cert_manager = true`. The TLS Secret
stays in both cases. Delete what you no longer use:

```bash
kubectl delete certificate langsmith-tls -n langsmith   # your tls_secret_name
kubectl delete clusterissuer letsencrypt-prod
```
