# LangSmith Azure — Parity + Ingress Expansion Plan
# Updated 2026-03-28
# Status: [ ] todo  [~] in progress  [x] done

## Goal

1. **AWS parity** — bring Azure to the same operator experience as AWS: `quickstart` wizard, `manage-keyvault` secret manager, ESO-backed secret syncing, and the same make-command flow.
2. **Ingress expansion** — support 5 ingress options: `nginx`, `istio`, `istio-addon`, `agic`, `envoy-gateway`, each with a clear DNS story.
3. **DNS clarity** — document and implement each DNS path so an SA can pick the right one in 30 seconds.

---

## Current State vs Target State

| Feature | AWS | Azure (current) | Azure (target) |
|---|---|---|---|
| Interactive wizard | `make quickstart` | ✗ | `make quickstart` |
| Secret manager UI | `make ssm` (6 subcommands) | ✗ | `make keyvault` (6 subcommands) |
| Secret sync | ESO (hourly auto-sync) | `create-k8s-secrets.sh` (one-shot) | Keep script + ESO option |
| Terraform Helm path | `make apply-app` ✅ | ✗ | `make apply-app` ✅ **done** |
| Ingress options | ALB only | nginx, istio, istio-addon | + agic, envoy-gateway ✅ **done** |
| Auto-DNS | ALB hostname | dns_label (Azure public IP DNS) | per-ingress auto-DNS ✅ **done** |
| Custom domain TLS | ACM | Let's Encrypt / Front Door | unchanged + AGIC cert |
| `make status` | 10-section | 9-section | 10-section (parity) |
| Sizing profiles | 4 profiles + SIZING.md ✅ | 4 profiles + SIZING.md ✅ **done** | unchanged |
| Addon flags | tfvars + init-values | tfvars + init-values | unchanged |

---

## Ingress Options

### Option 1: NGINX (default, recommended for most deployments)

**How it works:** `ingress-nginx` Helm chart creates a LoadBalancer service with a public Azure IP.

**DNS:**
- `dns_label = "myco-langsmith"` → auto-assigns `myco-langsmith.eastus.cloudapp.azure.com` (no DNS zone needed)
- OR `langsmith_domain = "langsmith.example.com"` with your own CNAME to the IP

**TLS:**
- `letsencrypt-http` — cert-manager HTTP-01 against the dns_label hostname
- `letsencrypt-dns` — cert-manager DNS-01 (requires `create_dns_zone = true`)
- `frontdoor` — Azure Front Door terminates TLS, forwards HTTP to nginx
- `existing` — bring your own K8s TLS secret

**Best for:** Standard deployments, no service mesh needed, simplest setup.

---

### Option 2: Istio (self-managed via Helm)

**How it works:** Installs `istio/base`, `istio/istiod`, and `istio/gateway` via Helm. Creates an Istio IngressGateway LoadBalancer service. Requires Gateway API CRDs.

**DNS:**
- Public IP of the `istio-ingressgateway` service — no auto DNS label (unlike nginx)
- Must set `langsmith_domain` and point it at the IP via A record
- OR use Front Door in front

**TLS:**
- cert-manager with `Gateway` + `HTTPRoute` resources (Gateway API)
- `frontdoor` — Front Door terminates TLS, forwards to Istio gateway

**Best for:** Deployments that need mTLS between services, or existing Istio mesh.

**Terraform:** `ingress_controller = "istio"`, `istio_version = "1.29.1"` (pinned)

---

### Option 3: Azure Managed Istio (AKS Istio Add-on)

**How it works:** AKS `azureServiceMesh` add-on. Azure manages the Istio control plane (upgrades, HA). Installs an Istio IngressGateway external to the Helm chart. Requires Gateway API CRDs.

**DNS:** Same as self-managed Istio — no auto DNS label.

**TLS:** Same as self-managed Istio.

**Best for:** Azure-managed control plane (SLA-backed), prefer not running Istio Helm yourself.

**Terraform:** `ingress_controller = "istio-addon"`, `istio_addon_revision = "asm-1-27"`

> **Note:** Revision must match an available AKS service mesh revision. Check: `az aks mesh get-upgrades -g <rg> -n <cluster>`

---

### Option 4: AGIC — Application Gateway Ingress Controller

**How it works:** Creates an Azure Application Gateway (v2) and installs the AGIC Helm chart. AGIC watches Kubernetes Ingress resources and programs AGW rules directly. Requires a dedicated subnet.

**DNS:**
- Application Gateway gets a public IP with an FQDN: `{name}-pip.{region}.cloudapp.azure.com` (auto-assigned)
- OR `langsmith_domain` pointing at the AGW public IP

**TLS:**
- AGW-native SSL: upload cert to Key Vault, AGW reads it via Managed Identity
- cert-manager DNS-01 (HTTP-01 is not compatible with AGW in most configurations)
- `frontdoor` — AGW can sit behind Front Door

**WAF integration:** Application Gateway v2 has native WAF support — no separate WAF module needed when using AGIC.

**Best for:** Enterprise Azure customers already running Application Gateway, want native WAF, align with Azure-native ingress patterns (similar to AWS ALB + LBC).

**Terraform:** `ingress_controller = "agic"` ✅ implemented

---

### Option 5: Envoy Gateway

**How it works:** CNCF Envoy Gateway (`envoyproxy/gateway-helm`) implements the Kubernetes Gateway API. Creates an Envoy proxy LoadBalancer. No relation to Istio — pure Envoy.

**DNS:**
- Public IP of the Envoy Gateway listener — no auto DNS label
- Must set `langsmith_domain` and point CNAME/A record

**TLS:**
- cert-manager with Gateway API (`Gateway` + `HTTPRoute` resources)
- `tls_certificate_source = "letsencrypt-http"` or `"letsencrypt-dns"`

**Best for:** Gateway API-native deployments, Envoy ecosystem, avoiding Istio complexity.

**Terraform:** `ingress_controller = "envoy-gateway"` ✅ implemented

---

## DNS Decision Guide

```
Q: Do you have your own domain?
  YES → set langsmith_domain = "langsmith.example.com"
        Q: Which TLS?
          cert-manager HTTP-01 → tls_certificate_source = "letsencrypt"
          cert-manager DNS-01 (no public HTTP needed) → tls_certificate_source = "dns01"
                                                         + create_dns_zone = true
          Bring your cert → tls_certificate_source = "existing"

  NO (need auto hostname):
    Set dns_label = "myco-langsmith"
    → hostname: myco-langsmith.{region}.cloudapp.azure.com
    → works for nginx, istio, istio-addon, envoy-gateway
    → deploy.sh annotates the correct LB service automatically
    → tls_certificate_source = "letsencrypt"  ← simplest path

    Using AGIC? → AGW auto-FQDN is assigned (less readable)
                  → better to bring your own domain
```

---

## Implementation Tasks

### Completed

| Item | Status | Notes |
|---|---|---|
| `app/` Terraform Helm module | [x] done | `app/main.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `versions.tf`, `backend.tf.example`, `terraform.tfvars.example`, `scripts/pull-infra-outputs.sh` |
| `make init-app` / `plan-app` / `apply-app` / `destroy-app` / `deploy-all-tf` | [x] done | Makefile updated |
| SIZING.md for Azure | [x] done | `helm/values/examples/SIZING.md` — matches AWS sizing numbers |
| Sizing YAML files updated to match SIZING.md | [x] done | `langsmith-values-sizing-dev.yaml`, `langsmith-values-sizing-minimum.yaml` updated |
| README.md command glossary | [x] done | All 5 new targets documented |
| QUICK_REFERENCE.md updated | [x] done | Terraform Helm path, Day-2 ops, Deployment Summary table |
| docs/content/azure/quick-reference.md synced | [x] done | Mirrors QUICK_REFERENCE.md |
| `quickstart.sh` + `make quickstart` | [x] done | `infra/scripts/quickstart.sh` — 10-section wizard, writes terraform.tfvars |
| `manage-keyvault.sh` + `make keyvault` | [x] done | `infra/scripts/manage-keyvault.sh` — 6 subcommands: list/get/set/validate/diff/delete |
| SA_WRITEUP.md for Azure | [x] done | `terraform/azure/SA_WRITEUP.md` — mirrors AWS SA_WRITEUP.md |
| `status.sh` section 10 (Terraform Helm App) | [x] done | Added `APP_DIR`, section 10, fixed ingress IP check (all controllers), removed stale Front Door ref |

---

### Phase 1: AWS Parity (no new infrastructure)

#### 1.1 `make quickstart` — Interactive setup wizard

**File:** `infra/scripts/quickstart.sh`

Mirrors `aws/infra/scripts/quickstart.sh`. Prompts for:
- `identifier`, `environment`, `location`, `subscription_id`
- `ingress_controller` (choice menu: nginx / istio / istio-addon / agic / envoy-gateway)
- TLS/DNS path (based on ingress choice)
- `dns_label` (if nginx selected)
- `langsmith_domain` (if custom domain)
- `tls_certificate_source`
- `letsencrypt_email` (if letsencrypt selected)
- `create_frontdoor` (optional)
- Postgres/Redis/ClickHouse sources
- Node pool sizing (vm_size, min/max_count)
- Sizing profile
- Addons (deployments, agent_builder, insights, polly)
- `keyvault_purge_protection` (default false for dev)
- `create_diagnostics`

Writes `infra/terraform.tfvars`.

**Makefile target:**
```makefile
quickstart: ## Interactive setup wizard — generates terraform.tfvars
    $(INFRA_DIR)/scripts/quickstart.sh
```

---

#### 1.2 `make keyvault` — Key Vault secret manager

**File:** `infra/scripts/manage-keyvault.sh`

Mirrors `aws/infra/scripts/manage-ssm.sh` but uses `az keyvault secret` commands.

**Subcommands:**

| Subcommand | What it does |
|---|---|
| `list` | `az keyvault secret list` — shows all secrets with last-updated timestamps |
| `get <key>` | `az keyvault secret show --name <key>` — decrypts and prints value |
| `set <key> <value>` | `az keyvault secret set` — validates format (admin password symbol check), warns on stable secrets |
| `validate` | Checks all required secrets exist and are non-empty |
| `diff` | Compares Key Vault vs `langsmith-config-secret` K8s Secret — shows missing/mismatched keys |
| `delete <key>` | Soft-deletes (double confirm for stable secrets) |

**Required secrets:**
- `postgres-password`
- `langsmith-license-key`
- `langsmith-admin-password`
- `langsmith-api-key-salt` *(stable — warn on change)*
- `langsmith-jwt-secret` *(stable — warn on change)*

**Optional secrets:**
- `deployments-encryption-key`
- `agent-builder-encryption-key`
- `insights-encryption-key`
- `polly-encryption-key`

**Makefile target:**
```makefile
keyvault: ## Interactive Key Vault secret manager
    $(INFRA_DIR)/scripts/manage-keyvault.sh
```

**Sync command after updating:**
```bash
make k8s-secrets   # re-runs create-k8s-secrets.sh to sync KV → K8s secret
```

---

#### ~~1.3 `make status` — Add 10th section (Terraform Helm App)~~ [x] done

Section 10 added. Also fixed: ingress LB IP check now dispatches per `ingress_controller` (nginx/istio-addon/istio/envoy-gateway), removed stale Front Door TLS reference.

---

### Phase 2: Ingress Expansion [x] done

#### 2.1 Add `agic` ingress option [x] done

**Completed:**
- `infra/variables.tf` — `"agic"` added to validation; `agic_subnet_address_prefix`, `agw_sku_tier` variables added
- `infra/modules/networking/variables.tf` + `main.tf` + `outputs.tf` — `enable_agic` flag, `azurerm_subnet.subnet_agic`, `subnet_agic_id` output
- `infra/modules/k8s-cluster/variables.tf` — `subscription_id`, `agic_subnet_id`, `agw_sku_tier` variables added
- `infra/modules/k8s-cluster/main.tf` — App Gateway v2 + public IP + AGIC managed identity + role assignments (Contributor on AGW, Reader on RG) + federated credential + AGIC Helm chart (Workload Identity ARM auth)
- `infra/modules/k8s-cluster/outputs.tf` — `agw_public_ip_address`, `agw_public_ip_fqdn`, `agw_name`
- `infra/main.tf` — `enable_agic`/`agic_subnet_address_prefix` wired to vnet; `agic_subnet_id` from vnet → aks; `subscription_id`, `agw_sku_tier`, `envoy_gateway_version` passed to aks
- `infra/outputs.tf` — `agw_public_ip_fqdn`, `agw_name` outputs; `langsmith_url` includes AGIC FQDN branch
- `helm/values/examples/langsmith-values-ingress-agic.yaml` — AGIC annotations + cert-manager TLS example
- `init-values.sh` — `agic) _ingress_class="azure/application-gateway"` case; AGW FQDN hostname detection from `terraform output agw_public_ip_fqdn`

---

#### 2.2 Add `envoy-gateway` ingress option [x] done

**Completed:**
- `infra/variables.tf` — `"envoy-gateway"` added to validation; `envoy_gateway_version` variable added
- `infra/modules/k8s-cluster/variables.tf` — `envoy_gateway_version` variable
- `infra/modules/k8s-cluster/main.tf` — `helm_release.envoy_gateway` (OCI chart `oci://docker.io/envoyproxy/gateway-helm`, namespace `envoy-gateway-system`)
- `helm/values/examples/langsmith-values-ingress-envoy-gateway.yaml` — Gateway API (GatewayClass + Gateway + HTTPRoute) instructions + `ingress.enabled: false`

---

#### 2.3 Confirm existing `istio` and `istio-addon` options [x] done

- `helm/values/examples/langsmith-values-ingress-istio.yaml` — Istio ingressClassName reference values with cert-manager TLS

---

### Phase 3: DNS/TLS Expansion

#### 3.1 Per-ingress DNS auto-detection in `init-values.sh`

Current `init-values.sh` generates the hostname from: `langsmith_domain` → `dns_label` (works for all ingress types) → existing → prompt. **Front Door removed.**

Need to extend for AGIC:

```
hostname priority (current, all ingress types):
  1. langsmith_domain (always wins)
  2. dns_label.{region}.cloudapp.azure.com (nginx/istio/istio-addon/envoy-gateway)
  3. agw auto-FQDN from terraform output (if ingress = agic) ← TODO
  4. existing hostname in overrides file
  5. prompt user
```

New terraform output needed: `agw_public_ip_fqdn` (from Application Gateway public IP resource).

#### 3.2 New `tls_certificate_source` values

Current: `none`, `letsencrypt`, `existing`

Proposed expanded values:
- `none` — HTTP only
- `letsencrypt` — cert-manager HTTP-01 (default)
- `dns01` — cert-manager DNS-01 (requires Azure DNS zone)
- `existing` — bring your own K8s TLS secret
- `agw-cert` — Application Gateway native Key Vault cert (only valid for `ingress_controller = agic`)

**Note:** Keep `letsencrypt` as alias for `letsencrypt-http` for backward compatibility.

**Validation update:**
```hcl
validation {
  condition = contains(["none", "letsencrypt", "letsencrypt-http", "letsencrypt-dns",
                        "frontdoor", "existing", "agw-cert"], var.tls_certificate_source)
  ...
}
```

---

### Phase 4: Documentation

- [ ] Update `README.md` — Command Glossary section (mirror AWS README style)
- [ ] Update `QUICK_REFERENCE.md` — Add ingress selection table
- [ ] Update `ARCHITECTURE.md` — Add ingress topology diagrams for each option
- [ ] Add `helm/values/examples/langsmith-values-ingress-agic.yaml`
- [ ] Add `helm/values/examples/langsmith-values-ingress-istio.yaml`
- [ ] Add `helm/values/examples/langsmith-values-ingress-envoy-gateway.yaml`

---

## Priority Order

| Priority | Task | Effort | Value |
|---|---|---|---|
| **P1** | `manage-keyvault.sh` + `make keyvault` | M | High — missing parity gap SAs hit immediately |
| **P1** | `quickstart.sh` + `make quickstart` | L | High — removes manual tfvars editing |
| **P2** | AGIC ingress option | L | High — Azure-native ingress (analogous to AWS ALB+LBC) |
| **P2** | Envoy Gateway ingress option | M | Medium — modern Gateway API path |
| **P2** | Extend `init-values.sh` for Istio/AGIC/Envoy hostname detection | S | High |
| **P3** | Expand `tls_certificate_source` values | S | Medium |
| **P3** | status.sh section 10 | S | Low |
| **P3** | README Command Glossary | S | Medium |

---

## Secret Flow Comparison (AWS vs Azure)

| Step | AWS | Azure |
|---|---|---|
| First run | `source setup-env.sh` → prompts → stores in SSM | `source setup-env.sh` → prompts → stores in Key Vault via Terraform |
| Subsequent runs | `source setup-env.sh` → reads from SSM silently | `source setup-env.sh` → reads from Key Vault silently |
| K8s sync | ESO polls SSM every hour automatically | `make k8s-secrets` runs `create-k8s-secrets.sh` (manual) |
| Secret management | `make ssm` → `manage-ssm.sh` | `make keyvault` → `manage-keyvault.sh` *(to build)* |
| Rotation workflow | `make ssm set <key>` → ESO auto-syncs within 1h | `make keyvault set <key>` → `make k8s-secrets` |

**Note on ESO for Azure:** ESO can also be used on Azure (it supports Azure Key Vault as a provider). If ESO is already installed by the k8s-bootstrap module, we could add a `ClusterSecretStore` backed by Key Vault and an `ExternalSecret`, eliminating the need for `create-k8s-secrets.sh`. This is a future upgrade path — the current `create-k8s-secrets.sh` approach works reliably and is simpler to debug.

---

## Ingress Compatibility Matrix

| Ingress | TLS: none | TLS: letsencrypt-http | TLS: letsencrypt-dns | TLS: frontdoor | TLS: existing | TLS: agw-cert |
|---|---|---|---|---|---|---|
| `nginx` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| `istio` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| `istio-addon` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| `agic` | ✓ | ✗* | ✓ | ✓ | ✓ | ✓ |
| `envoy-gateway` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |

*AGIC + HTTP-01: Application Gateway sits in front of nginx and rewrites paths, breaking the ACME challenge endpoint. Use DNS-01 instead.

---

## Known Gaps Not in This Plan

- **Multi-dataplane** ingress (multiple listeners per namespace) — out of scope for this plan, tracked in use-cases/
- **Private AKS with AGIC** — AGIC in private cluster mode requires AKS-AGIC addon (not Helm chart). Different implementation path.
- **Azure DNS auto-delegation** for DNS-01 — requires Azure DNS zone ownership. Out of scope; document as prerequisite.
- **IPv6** — not planned for any ingress option.
