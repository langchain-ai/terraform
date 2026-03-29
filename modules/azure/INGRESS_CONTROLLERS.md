# LangSmith Azure — Ingress Controller Guide

Tested ingress controllers for LangSmith on AKS. Each controller is a standalone deployment pattern — switch by changing `ingress_controller` in `terraform.tfvars` and re-running `make apply`.

---

## Quick Comparison

| Controller | `ingress_controller` value | How it works | `dns_label` support | Notes |
|---|---|---|---|---|
| **nginx** | `nginx` | K8s Ingress via NGINX ingress controller Helm chart | Yes — LB service annotation | Simplest, recommended default |
| **istio** | `istio` | Self-managed Istio via Helm (istiod + ingressgateway) | Yes — LB service annotation | Full mesh features available |
| **istio-addon** | `istio-addon` | AKS managed Istio Service Mesh add-on | Yes — LB service annotation | No Helm install, Azure managed revision |
| **agic** | `agic` | Azure Application Gateway via AKS add-on | Yes — AGW public IP `domain_name_label` | L7 WAF built-in when `agw_sku_tier = "WAF_v2"` |
| **envoy-gateway** | `envoy-gateway` | Envoy Gateway with Kubernetes Gateway API | Yes — LB service annotation | Gateway API (not Ingress), most modern |

---

## terraform.tfvars Snippets

### nginx (default, simplest)

```hcl
ingress_controller     = "nginx"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
langsmith_domain       = "langsmith-prod.eastus.cloudapp.azure.com"
```

**How it works:**
- Terraform installs the NGINX ingress controller via Helm chart
- `dns_label` sets `service.beta.kubernetes.io/azure-dns-label-name` annotation on the LB service
- cert-manager issues TLS via HTTP-01 using `ingressClassName: nginx`

---

### istio-addon (AKS managed)

```hcl
ingress_controller     = "istio-addon"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
langsmith_domain       = "langsmith-prod.eastus.cloudapp.azure.com"
```

**How it works:**
- AKS enables the managed Istio service mesh add-on (`istio_addon_revision` in tfvars)
- External gateway runs in `aks-istio-ingress` namespace with label `istio: aks-istio-ingressgateway-external`
- `dns_label` sets the DNS label annotation on the AKS-managed external gateway LB service
- `deploy.sh` creates:
  1. `ClusterIssuer` with `ingressClassName: istio`
  2. `networking.istio.io/v1beta1 Gateway` targeting `istio: aks-istio-ingressgateway-external`
  3. LangSmith `VirtualService`
  4. TLS secret synced to `aks-istio-ingress` namespace (gateway reads certs from its own namespace)

> **Watchout:** `ingressClassName: istio` targets label `istio: ingressgateway` — the AKS gateway has a different label. `make deploy` creates explicit Gateway + VirtualService instead of relying on Kubernetes Ingress.

---

### agic (Azure Application Gateway)

```hcl
ingress_controller     = "agic"
agw_sku_tier           = "Standard_v2"    # or "WAF_v2" for built-in WAF
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
langsmith_domain       = "langsmith-prod.eastus.cloudapp.azure.com"
```

**How it works:**
- Terraform creates an Azure Application Gateway + enables the `ingress_application_gateway` AKS add-on
- AKS provisions an `IngressClass` named `azure-application-gateway`
- `dns_label` sets `domain_name_label` on the AGW public IP resource (not a K8s annotation)
- AGIC watches `Ingress` resources with `ingressClassName: azure-application-gateway` and programs AGW routing rules
- cert-manager issues TLS via HTTP-01 using `ingressClassName: azure-application-gateway`

**Required role assignments for the AKS-provisioned AGIC identity:**
- Reader on the resource group
- Contributor on the Application Gateway
- Network Contributor on the VNet (for subnet join action)

> All three roles are automated in Terraform via data source lookup of the add-on identity. For manually provisioned clusters, use `az role assignment create` (see TROUBLESHOOTING.md).

**Enable WAF:**
```hcl
agw_sku_tier = "WAF_v2"
```
No separate WAF module needed — WAF is built into the Application Gateway.

---

### istio (self-managed Helm)

```hcl
ingress_controller     = "istio"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
langsmith_domain       = "langsmith-prod.eastus.cloudapp.azure.com"
```

**How it works:**
- Terraform installs `istio-base` (CRDs), `istiod` (control plane), and `istio-ingressgateway` via Helm
- istiod configured with `meshConfig.ingressControllerMode: STRICT` + `meshConfig.ingressClass: istio`
- Gateway runs in `istio-system` with label `istio: ingressgateway`
- Standard Kubernetes Ingress with `ingressClassName: istio`
- `deploy.sh` creates the `istio` IngressClass resource (required for istiod to generate listeners)
- `deploy.sh` syncs the `langsmith-tls` secret to `istio-system` after cert issuance (required for SDS TLS delivery to the gateway)

> **Watchouts:**
> - Without `meshConfig.ingressControllerMode: STRICT`, istiod ignores Ingress resources — LDS push has 0 listeners
> - Without the `istio` IngressClass resource, istiod won't generate listeners even with STRICT mode
> - TLS secret must be copied to `istio-system` — istiod serves it to the gateway via SDS (`kubernetes://langsmith-tls`)
> - All three issues are handled automatically by `make deploy`

---

### envoy-gateway (Gateway API)

```hcl
ingress_controller     = "envoy-gateway"
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
langsmith_domain       = "langsmith-prod.eastus.cloudapp.azure.com"
```

**How it works:**
- Terraform installs Envoy Gateway via Helm chart + installs Gateway API CRDs
- Uses Kubernetes Gateway API (`GatewayClass` → `Gateway` → `HTTPRoute`) instead of `Ingress`
- `deploy.sh` creates all Gateway API resources automatically:
  1. `GatewayClass` named `langsmith-eg` (controller: `gateway.envoyproxy.io/gatewayclass-controller`)
  2. `Gateway` in the langsmith namespace with HTTP + HTTPS listeners
  3. `HTTPRoute` routing all traffic to `langsmith-frontend`
- LangSmith Helm `ingress.enabled: false` — traffic flows via Gateway API only
- `dns_label` sets the Azure DNS label annotation on the Envoy Gateway LB service in `envoy-gateway-system` namespace (label: `gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway`)

**TLS:**
- cert-manager uses `gatewayHTTPRoute` solver (not `ingress` HTTP-01)
- Requires cert-manager v1.14+ with `ExperimentalGatewayAPISupport=true` feature gate
- `deploy.sh` enables the feature gate automatically via `kubectl patch`

> **Note:** The Envoy Gateway LB service is in `envoy-gateway-system` namespace, not the langsmith namespace. The DNS label annotation must be applied there, not on `langsmith-frontend`.

---

## Switching Controllers

Change `ingress_controller` in `terraform.tfvars`, then:

```bash
# 1. Uninstall LangSmith first (frees LB resources)
make uninstall

# 2. Re-apply infrastructure (switches controller)
make apply

# 3. Get fresh kubeconfig (in case cluster was recreated)
make kubeconfig

# 4. Re-create K8s secrets
make k8s-secrets

# 5. Re-generate values and re-deploy
make init-values
make deploy
```

Or one-shot:
```bash
make uninstall && make apply && make kubeconfig && make k8s-secrets && make init-values && make deploy
```

---

## Helm Values Examples

Per-controller overlay files in `helm/values/examples/`:

| File | Controller |
|---|---|
| `langsmith-values-ingress-agic.yaml` | AGIC |
| `langsmith-values-ingress-istio.yaml` | istio / istio-addon |
| `langsmith-values-ingress-envoy-gateway.yaml` | envoy-gateway |

NGINX uses the default values — no dedicated overlay needed.

---

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for per-controller gotchas:
- AGIC: add-on identity role assignments (Reader on RG, Contributor on AGW, Network Contributor on VNet)
- istio-addon: gateway label mismatch, TLS secret namespace sync
- Envoy Gateway: Gateway API vs Ingress distinction
