# LangSmith Azure — Ingress & TLS Guide

All controllers and TLS paths below have been **end-to-end validated** on AKS (chart 0.13.38)
including LangGraph Platform (Passes 3–5, `enable_deployments = true`).

Switch by changing `ingress_controller` in `terraform.tfvars` and re-running `make apply`.

---

## TLS Compatibility Matrix

**Invalid combinations fail silently or produce a broken cert — use this table before choosing.**

| Controller | `letsencrypt` (HTTP-01) | `dns01` (DNS-01) | `none` (HTTP only) |
|---|---|---|---|
| **nginx** | ✅ Validated | ✅ Validated (langsmith.example.com) | ✅ Validated |
| **istio-addon** | ❌ No IngressClass — HTTP-01 solver cannot receive traffic | ✅ Requires custom domain | ✅ Validated |
| **istio** (self-managed) | ✅ Validated | ✅ Requires custom domain | ✅ Validated |
| **agic** | ❌ AGW rewrites ACME challenge path | ✅ Requires custom domain | ✅ Validated (Standard_v2) |
| **envoy-gateway** | ✅ Validated | ✅ Requires custom domain | ✅ Validated |

### Why istio-addon + letsencrypt fails

The AKS managed Istio addon does **not** create a Kubernetes `IngressClass` resource.
cert-manager's HTTP-01 solver creates a temporary `Ingress` with `ingressClassName: istio`,
but with no IngressClass registered, Istiod ignores it — the ACME challenge never gets
routed and the cert times out. **Confirmed in testing: `kubectl get ingressclass` returns empty.**

**For istio-addon + TLS:** use `dns01` with a custom domain (cert-manager validates via
Azure DNS API using Workload Identity — no HTTP routing required).

### Why agic + letsencrypt fails

Azure Application Gateway rewrites all paths. The ACME HTTP-01 challenge endpoint
(`/.well-known/acme-challenge/<token>`) gets modified or absorbed by AGW health probes,
and Let's Encrypt cannot verify the token.

**For agic + TLS:** always use `dns01` with a custom domain.

---

## Quick Decision Guide

```
Do you have a custom domain (langsmith.mycompany.com)?
│
├── No  → Use dns_label (Azure free subdomain: <label>.eastus.cloudapp.azure.com)
│         ├── Want HTTPS?  → nginx + letsencrypt  ✅ (5 min, just need an email)
│         └── HTTP ok?     → nginx + none         ✅ (fastest, quickstart default)
│
└── Yes → langsmith_domain + create_dns_zone = true + NS delegation at registrar
          └── Any controller → dns01  ✅ (works behind firewalls, no port 80 needed)
```

---

## Controller Reference

### nginx — recommended default

**Validated: ✅ nginx + none (HTTP) — full 5-pass including LangGraph Platform, Agent Builder, Insights, Polly**
**Validated: ✅ nginx + letsencrypt (HTTPS) — full 5-pass including LangGraph Platform, Agent Builder, Insights, Polly**
**Validated: ✅ nginx + letsencrypt + external postgres + external redis — Pass 3, managed Azure services**
**Validated: ✅ nginx + none + production sizing profile — multi-replica HPA, Standard_D8s_v3 ×3**

```hcl
# Quickstart default — HTTP, zero cert setup
ingress_controller     = "nginx"
dns_label              = "langsmith-prod"
tls_certificate_source = "none"
```

```hcl
# With HTTPS via Let's Encrypt (just add letsencrypt_email)
ingress_controller     = "nginx"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
```

**How it works:**
- Terraform installs the NGINX ingress controller via Helm chart
- `dns_label` sets `service.beta.kubernetes.io/azure-dns-label-name` on the LB service
- cert-manager issues TLS via HTTP-01 using `ingressClassName: nginx`
- LangSmith Helm chart creates an `Ingress` resource with `ingressClassName: nginx`

**URL:** `http://langsmith-prod.eastus.cloudapp.azure.com` (or `https://` with letsencrypt)

---

### istio-addon — AKS managed Istio mesh

**Validated: ✅ istio-addon + none (HTTP) — full 5-pass including LangGraph Platform**
**Validated: ✅ istio-addon + none + production sizing — multi-replica HPA, Standard_D8s_v3 ×3**
**TLS constraint: ⚠️ `letsencrypt` NOT supported — use `dns01` or `none`**

```hcl
# HTTP-only (dev/internal, no cert needed)
ingress_controller     = "istio-addon"
istio_addon_revision   = "asm-1-27"       # check: az aks mesh get-upgrades -g <rg> -n <cluster>
dns_label              = "langsmith-prod"
tls_certificate_source = "none"
```

```hcl
# HTTPS via DNS-01 (production, requires custom domain)
ingress_controller     = "istio-addon"
istio_addon_revision   = "asm-1-27"
langsmith_domain       = "langsmith.mycompany.com"
tls_certificate_source = "dns01"
letsencrypt_email      = "you@example.com"
create_dns_zone        = true
```

**How it works:**
- AKS enables the managed Istio add-on (Azure manages the revision — no Helm install)
- External gateway pod in `aks-istio-ingress` ns, label: `istio: aks-istio-ingressgateway-external`
- `dns_label` sets the DNS label annotation on the AKS-managed external gateway LB service
- `deploy.sh` creates a `networking.istio.io/v1beta1 Gateway` targeting the external gateway selector
- LangSmith Helm chart creates the `VirtualService` via `istioGateway.enabled: true` in values
- For dns01: TLS secret synced to `aks-istio-ingress` namespace after cert issuance

**Why Gateway + VirtualService instead of Kubernetes Ingress:**
The AKS external gateway label is `istio: aks-istio-ingressgateway-external`.
Kubernetes Ingress with `ingressClassName: istio` targets `istio: ingressgateway` — a mismatch.
`make deploy` creates an explicit `Gateway` resource with the correct selector.

**For LangGraph Platform (`enable_deployments = true`):**
`init-values.sh` automatically sets `istioGateway.enabled: true` with `name: langsmith-gateway`
in `values-overrides.yaml`. Required for chart validation — no manual steps needed.

**URL:** `http://langsmith-prod.eastus.cloudapp.azure.com` (or `https://` with dns01)

---

### agic — Azure Application Gateway

**Validated: ✅ agic + none (HTTP) — Standard_v2, LangGraph Platform (`enable_deployments = true`)**
**TLS constraint: ⚠️ `letsencrypt` NOT supported — must use `dns01` + custom domain**

```hcl
# HTTP-only (validated)
ingress_controller     = "agic"
agw_sku_tier           = "Standard_v2"    # or "WAF_v2" for built-in WAF
dns_label              = "langsmith-prod"
tls_certificate_source = "none"
```

```hcl
# HTTPS via DNS-01 (requires custom domain)
ingress_controller     = "agic"
agw_sku_tier           = "Standard_v2"
langsmith_domain       = "langsmith.mycompany.com"
tls_certificate_source = "dns01"
letsencrypt_email      = "you@example.com"
create_dns_zone        = true
```

**How it works:**
- Terraform creates Application Gateway v2 + dedicated `/24` subnet
- AKS provisions `IngressClass` named `azure-application-gateway`
- AGIC watches `Ingress` resources and programs AGW routing rules
- cert-manager issues TLS via DNS-01 (HTTP-01 incompatible with AGW path rewriting)
- Three role assignments automated by Terraform: Reader on RG, Contributor on AGW, Network Contributor on VNet

**RBAC timing — known issue:** The AKS AGIC addon creates its managed identity during cluster
provisioning, but the identity requires ~5 minutes to register in Azure AD before role assignments
take effect. Terraform adds a `time_sleep` of 300s between cluster creation and role assignment
creation to prevent the AGIC controller from entering CrashLoopBackOff with persistent 403 errors.
Without this delay, AGIC fails immediately and requires `az aks update` to trigger reconciliation.

**Enable WAF:** set `agw_sku_tier = "WAF_v2"` — built into AGW, no separate WAF module needed.

> **AGIC requires full cluster rebuild** to enable — the AGW subnet must be provisioned at
> VNet creation time and cannot be added to an existing VNet.

---

### istio — self-managed via Helm

**Validated: ✅ istio + none (HTTP), istio + letsencrypt (HTTPS) — full 5-pass including LangGraph Platform**

```hcl
# HTTP only
ingress_controller     = "istio"
dns_label              = "langsmith-prod"
tls_certificate_source = "none"
```

```hcl
# HTTPS via Let's Encrypt
ingress_controller     = "istio"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
```

**How it works:**
- Terraform installs `istio-base` (CRDs), `istiod`, and `istio-ingressgateway` via Helm
- Gateway in `istio-system` with label `istio: ingressgateway`
- `deploy.sh` creates the `istio` IngressClass resource (required — istiod won't generate listeners without it)
- LangSmith chart uses `ingress.enabled: true`, `ingressClassName: istio` — creates K8s Ingress → Istio VS
- `deploy.sh` syncs `langsmith-tls` to `istio-system` after cert issuance (SDS delivery to gateway pod)

> Unlike `istio-addon`, self-managed Istio **does** support `letsencrypt` — `deploy.sh` creates
> the `istio` IngressClass that the HTTP-01 solver requires.

---

### envoy-gateway — Kubernetes Gateway API

**Validated: ✅ envoy-gateway + none (HTTP), envoy-gateway + letsencrypt (HTTPS) — full 5-pass including LangGraph Platform**

```hcl
# HTTP only
ingress_controller     = "envoy-gateway"
dns_label              = "langsmith-prod"
tls_certificate_source = "none"
```

```hcl
# HTTPS via Let's Encrypt
ingress_controller     = "envoy-gateway"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
```

**How it works:**
- Terraform installs Envoy Gateway via Helm + Gateway API CRDs
- `deploy.sh` creates `GatewayClass` + `Gateway` **before** helm install (required for chart validation)
- LangSmith chart uses `gateway.enabled: true` (Gateway API mode) — creates `HTTPRoute` resources
- `init-values.sh` sets `gateway.enabled: true`, `gateway.name: langsmith-gateway`, `gateway.namespace: langsmith`
- cert-manager uses `gatewayHTTPRoute` solver + `ExperimentalGatewayAPISupport=true` feature gate
- DNS label applied to Envoy LB service in `envoy-gateway-system` namespace (post-deploy)

**Key: Gateway is created pre-deploy.** Without this, chart validation fails when
`enable_deployments = true` (`Either ingress, gateway, or istioGateway must be enabled`).

**DNS label:** Applied to Envoy Gateway LB service in `envoy-gateway-system` namespace.

---

## dns01 — Custom Domain Path (Validated ✅)

**Validated: nginx + dns01 + custom domain (`langsmith.example.com`) — cert issued in < 4 min, HTTPS 200**

### How it works

```
Your registrar (Cloudflare, Route53, Squarespace, etc.)
  └── NS records for subdomain → Azure DNS zone
        └── cert-manager (Workload Identity) writes TXT record:
              _acme-challenge.langsmith.mycompany.com = <token>
                └── Let's Encrypt validates → issues cert
                      └── cert-manager stores cert as K8s secret → nginx serves HTTPS
```

cert-manager uses **Workload Identity** (no static credentials) to write TXT records in the Azure DNS zone. The managed identity is created by Terraform and scoped to DNS Zone Contributor on that zone only.

### Why NS records, not CNAME

A CNAME aliases traffic but does not delegate DNS authority. cert-manager needs to **write** TXT records to the zone — that requires Azure DNS to be **authoritative** for the subdomain. NS delegation transfers that authority. CNAME alone will cause the DNS-01 challenge to fail.

### Step-by-step

1. **Set in `terraform.tfvars`:**
   ```hcl
   ingress_controller     = "nginx"         # works with all controllers
   tls_certificate_source = "dns01"
   langsmith_domain       = "langsmith.mycompany.com"
   create_dns_zone        = true
   letsencrypt_email      = "you@example.com"
   ```

2. **`make apply`** — creates the Azure DNS zone, outputs 4 nameservers

3. **Get the nameservers:**
   ```bash
   terraform -chdir=infra output dns_nameservers
   # → ns1-04.azure-dns.com. ns2-04.azure-dns.net. ...
   ```

4. **Add NS records at your registrar** (wherever the parent domain is managed):
   - Apex domain (`mycompany.com`): add 4 NS records for `langsmith` pointing to the Azure nameservers
   - Full domain (`mycompany.com`): replace existing NS records with the 4 Azure ones (delegates entire zone)

5. **Verify propagation** (usually < 5 min):
   ```bash
   dig NS langsmith.mycompany.com @8.8.8.8
   ```

6. **`make deploy`** — `deploy.sh` creates the DNS-01 ClusterIssuer automatically (azureDNS solver + Workload Identity). cert-manager issues the cert without any further manual steps.

7. **After deploy — get LB IP and set A record:**
   ```bash
   kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   # Add to terraform.tfvars: ingress_ip = "<lb-ip>"
   make apply   # creates A record in Azure DNS zone
   ```

   `make status` guides you through this — it prints the exact A record command if `ingress_ip` is not yet set.

> ⚠️ `create_dns_zone = true` with empty `langsmith_domain` causes a Terraform 502 error.
> Always set `langsmith_domain` before enabling `create_dns_zone`.

---

## Switching Controllers

```bash
make uninstall                              # remove Helm release, free LB resources
# edit terraform.tfvars: ingress_controller, tls_certificate_source
make apply                                  # install new controller
make kubeconfig && make k8s-secrets         # refresh credentials + secrets
make init-values && make deploy             # re-deploy LangSmith
```

> **AGIC requires full destroy/rebuild** — App Gateway subnet must exist at VNet creation time.

---

## How init-values.sh Configures Routing

`init-values.sh` generates the correct `values-overrides.yaml` block automatically:

| Controller | `ingress.enabled` | `istioGateway.enabled` | `gateway.enabled` | Routing mechanism |
|---|---|---|---|---|
| nginx | `true` | `false` | `false` | K8s Ingress → nginx |
| istio-addon | `false` | `true` (`name: langsmith-gateway`) | `false` | Gateway (deploy.sh) + VS (chart) |
| istio | `true` (`class: istio`) | `false` | `false` | K8s Ingress → Istio ingressgateway |
| agic | `true` | `false` | `false` | K8s Ingress → AGW rules |
| envoy-gateway | `false` | `false` | `true` (`name: langsmith-gateway`) | Gateway API HTTPRoute (chart) |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cert stuck Pending, `istio-addon` + `letsencrypt` | No IngressClass — not supported | Switch to `dns01` + custom domain, or `none` |
| Cert stuck Pending, `nginx` + `letsencrypt` | DNS label not on nginx LB | Re-run `make deploy` |
| Chart validation error: must enable ingress or gateway | LangGraph Platform enabled, istioGateway disabled | Re-run `make init-values && make deploy` |
| VirtualService ownership conflict on re-deploy | VS was created by kubectl, not Helm | `kubectl delete vs langsmith -n langsmith` then `make deploy` |
| `create_dns_zone` 502 error | `langsmith_domain` not set | Set `langsmith_domain` or `create_dns_zone = false` |
| AGW HTTP-01 cert fails | AGW rewrites ACME challenge path | Use `dns01` for AGIC |
| AGIC pod CrashLoopBackOff, persistent 403 on AGW | AGIC addon identity not yet registered in Azure AD when role assignments were created | Wait 5 min then run `az aks update --name <cluster> --resource-group <rg> --yes` — Terraform now adds a 300s `time_sleep` before role assignments to prevent this |
| `bool cannot unmarshal into string` on cert-manager | Missing `type = "string"` on podLabels set block | Fixed in k8s-bootstrap/main.tf — run `make apply` |
