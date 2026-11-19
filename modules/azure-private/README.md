# azure-private — Private / Hub-Spoke AKS Landing Zone for LangSmith

> **Deploying?** See **[DEPLOYMENT.md](DEPLOYMENT.md)** for the customer prerequisites
> (hub-and-spoke / firewall / apply-host requirements), the example tfvars, and the
> step-by-step runbook (Terraform infra → Helm app). This README is the reference for the
> input variables and the DNS / identity modes.
>
> **Just want to try it end to end?** [DEPLOYMENT.md](DEPLOYMENT.md)'s **Path A** stands up a
> throwaway hub-spoke landing zone + firewall (via [`test/hub-spoke/`](test/hub-spoke/)) and takes
> you from nothing to a running LangSmith.
>
> **Prefer a picture?** [architecture.html](architecture.html) is a one-page visual of what the
> module builds, what you bring as a prerequisite, and the deployment order — open it in a browser.

## What this is

`modules/azure-private` is an **opinionated, self-contained, forkable** private landing
zone for LangSmith on AKS. Every security control is **always on** — there are no opt-in
toggles. The module is a sibling to `modules/azure` (the simple managed/public quickstart)
and was vendored from it; the two modules now intentionally diverge.

The module is split into **two Terraform roots** that are applied in sequence:

- **`infra/`** — azurerm-only. Creates the AKS cluster, Postgres, Redis, Blob, Key Vault,
  bastion, and diagnostics. Has **no** Kubernetes or Helm providers. Run from anywhere —
  it is never blocked by the private API server.
- **`bootstrap/`** — in-cluster. Installs KEDA, the internal NGINX ingress,
  the `langsmith` namespace, and K8s secrets (read from Key Vault). Discovers everything it
  needs (cluster endpoint, kubeconfig, identities, connection strings) via Azure data sources
  and Key Vault — no dependency on `infra/` Terraform state. Must run **from the jumpbox**
  (inside the VNet) as a **separate apply run after** `infra/` completes.

The always-on posture:

- **BYO resource group + BYO VNet** (you pre-create both; the module consumes them).
- **Private API server** — AKS control plane has no public IP.
- **Azure CNI Overlay + Cilium** — pods draw IPs from `aks_pod_cidr`, not the subnet; eBPF
  dataplane.
- **UDR egress** — the AKS subnet's route table routes `0.0.0.0/0` to your firewall/NVA.
- **User-assigned control-plane identity** (module-created by default).
- **Internal NGINX ingress** — private IP only; no WAF, no public Azure DNS zone, no AGIC.
  Installed by `bootstrap/`.
- **Private Endpoints for Postgres and Redis** — the module creates the
  `privatelink.postgres.database.azure.com` and `privatelink.redis.azure.net` zones and
  links them to your VNet.

---

## Prerequisites

Everything in this section must exist **before** `terraform apply`.

### Resource group

An existing Azure resource group. The deployment region is **inherited from the RG** — you
do not set a `location` variable. You need at least Contributor on the RG.

### VNet and subnets

An existing VNet with the following subnets:

| Subnet | Requirements |
|--------|-------------|
| **AKS subnet** | Route table with `0.0.0.0/0` → firewall/NVA private IP (UDR). `Microsoft.Storage` and `Microsoft.KeyVault` service endpoints enabled (the Blob and Key Vault firewalls allowlist this subnet via these endpoints). |
| **Postgres PE subnet** | A regular subnet with at least one spare IP for the private endpoint. **Not delegated** — Postgres uses a Private Endpoint, not VNet injection. |
| **Redis PE subnet** | A regular subnet for the Redis private endpoint. |
| **Jumpbox subnet** | A normal subnet (e.g. `jumpbox`). The module always provisions a jumpbox VM here as the in-VNet apply host. |

### Firewall egress rules

The AKS subnet's route table sends all egress through your firewall. You must permit the
required AKS control-plane FQDNs and ports:
[https://learn.microsoft.com/azure/aks/limit-egress-traffic](https://learn.microsoft.com/azure/aks/limit-egress-traffic)

### In-VNet apply host

`terraform apply` must run from a host that **resolves the private DNS zone** for the AKS
API server. Options:

- The bastion jumpbox VM this module provisions (SSH in via the jumpbox's public IP, then
  run `terraform` there).
- A peered self-hosted CI/CD runner with a line of sight to the private DNS zone.

### RBAC

The Terraform principal needs:

- **Contributor** + **User Access Administrator** (or **Owner**) on the subscription/RG.
- **Network Contributor on the VNet** — so AKS can join the subnet and the module can grant
  the control-plane identity its Network Contributor role.

---

## Inputs

### Resource IDs

| Variable | Description |
|----------|-------------|
| `subscription_id` | Target subscription. |
| `resource_group_name` | Name of the existing RG (region is inherited). |
| `vnet_id` | Resource ID of the existing VNet. |
| `aks_subnet_id` | Resource ID of the AKS subnet. |
| `postgres_subnet_id` | Resource ID of the Postgres PE subnet (regular, not delegated). |
| `redis_subnet_id` | Resource ID of the Redis PE subnet. |
| `bastion_subnet_id` | Resource ID of the jumpbox subnet (a normal subnet, e.g. `.../subnets/jumpbox`). |

### Deployment metadata

| Variable | Default | Description |
|----------|---------|-------------|
| `identifier` | `""` | Short suffix appended to every resource name (e.g. `"-prod"`). |
| `environment` | `"dev"` | `dev`, `staging`, or `prod` — applied as a tag. |
| `owner` | `""` | Owner email/team tag. |
| `cost_center` | `""` | Cost center tag. |

### CIDRs

| Variable | Default | Description |
|----------|---------|-------------|
| `aks_pod_cidr` | `10.244.0.0/16` | Pod CIDR for Azure CNI Overlay. Must not overlap the VNet, `aks_service_cidr`, or peered/on-prem ranges. |
| `aks_service_cidr` | `10.0.64.0/20` | Kubernetes service CIDR. |
| `aks_dns_service_ip` | `10.0.64.10` | Kubernetes DNS service IP (must be within `aks_service_cidr`). |

### API-server private DNS

See [API-server private DNS](#api-server-private-dns) below.

| Variable | Default | Description |
|----------|---------|-------------|
| `aks_private_dns_zone_id` | `""` | Private DNS zone mode — see the section below. |
| `aks_private_cluster_public_fqdn_enabled` | `false` | Expose a public FQDN for the private API server. Required when `aks_private_dns_zone_id = "None"`. |

### Control-plane identity

See [Control-plane identity](#control-plane-identity) below.

| Variable | Default | Description |
|----------|---------|-------------|
| `aks_create_cluster_identity` | `true` | Create a module-managed user-assigned identity and grant it Network Contributor on the VNet. |
| `aks_cluster_identity_id` | `""` | BYO user-assigned identity resource ID. Mutually exclusive with `aks_create_cluster_identity`. |

### Key Vault

| Variable | Default | Description |
|----------|---------|-------------|
| `keyvault_name` | `""` | Key Vault name (globally unique, 3–24 chars). Defaults to `langsmith-kv<identifier>`. |
| `keyvault_purge_protection` | `true` | Set `false` for dev environments. |
| `keyvault_default_action` | `"Allow"` | Set `"Deny"` + `keyvault_allowed_ips` for production. |
| `keyvault_allowed_ips` | `[]` | Additional IPs/CIDRs for the Key Vault firewall (AKS subnet is added automatically). |

### Backing services

| Variable | Default | Description |
|----------|---------|-------------|
| `postgres_source` | `"external"` | `"external"` provisions Azure Database for PostgreSQL Flexible Server (recommended). `"in-cluster"` for dev/demo only. |
| `redis_source` | `"external"` | `"external"` provisions Azure Cache for Redis. `"in-cluster"` for dev/demo only. |
| `amr_sku` | `"Balanced_B0"` | Azure Managed Redis SKU. Increase if the region reports `AllocationFailed`. |
| `postgres_admin_username` | `"langsmith"` | Postgres admin username. |
| `postgres_admin_password` | — | Postgres admin password. Supply via `TF_VAR_postgres_admin_password`. |

### App inputs / secrets

| Variable | Description |
|----------|-------------|
| `langsmith_domain` | Hostname for the LangSmith ingress (e.g. `langsmith.internal.example.com`). |
| `langsmith_license_key` | LangSmith enterprise license key. Supply via `TF_VAR_langsmith_license_key`. |
| `langsmith_api_key_salt` | API key hash salt. Generate once: `openssl rand -base64 32`. Supply via env var. |
| `langsmith_jwt_secret` | JWT session secret. Generate once: `openssl rand -base64 32`. Supply via env var. |

### Node sizing

| Variable | Default | Description |
|----------|---------|-------------|
| `default_node_pool_vm_size` | `Standard_D8s_v3` | Default pool VM size (8 vCPU / 32 GiB). |
| `default_node_pool_min_count` | `1` | Min nodes. Set `3` for production. |
| `default_node_pool_max_count` | `10` | Max nodes for autoscaler. |
| `default_node_pool_max_pods` | `60` | Max pods per node (immutable). |
| `additional_node_pools` | `{large: Standard_D16s_v3}` | Extra node pools. The `large` pool is required for ClickHouse and LangGraph Platform. |
| `availability_zones` | `["1"]` | Set `["1","2","3"]` for zone-redundant HA. |

---

## API-server private DNS

> **Deep dive:** [PRIVATE_DNS.md](PRIVATE_DNS.md) explains exactly what *this Terraform* does
> versus what *AKS* does for each mode (zone creation, VNet linking, the control-plane identity
> + Network Contributor grant), and how it differs from the Postgres/Redis zones.

`aks_private_dns_zone_id` controls how the AKS private API server's DNS is resolved. Three
modes:

| Value | Behaviour |
|-------|-----------|
| `""` *(default)* | **System** — AKS creates and manages the private DNS zone automatically and links it to your VNet. The simplest option; works for most deployments. |
| `"None"` | **BYO DNS** — AKS creates no private DNS zone; resolution is your responsibility. Requires `aks_private_cluster_public_fqdn_enabled = true` so the API FQDN resolves publicly (e.g. via your own DNS server). AKS does not support `"None"` with a disabled public FQDN. |
| `<zone resource ID>` | **Custom zone** — supply the resource ID of your own `privatelink.<region>.azmk8s.io` zone. The zone must be linked to the VNet. You must also bring a BYO user-assigned identity (`aks_create_cluster_identity = false`, `aks_cluster_identity_id = "..."`) pre-granted **Private DNS Zone Contributor** on the zone and **Network Contributor** on the VNet. |

### Hub-spoke / custom DNS caveat

If your VNet uses custom DNS servers (common in hub-spoke), add conditional forwarders to
`168.63.129.16` for:

- `privatelink.<region>.azmk8s.io` (AKS API server zone, if using System or custom mode)
- `privatelink.postgres.database.azure.com`
- `privatelink.redis.azure.net`

Without these forwarders the in-VNet apply host and pods cannot resolve the private
endpoint FQDNs.

---

## Control-plane identity

The AKS control plane needs a managed identity with **Network Contributor on the VNet** to
join subnets and (in System DNS mode) link the private DNS zone.

| Mode | How to configure |
|------|-----------------|
| **Module-created (default)** | Leave `aks_create_cluster_identity = true` (default). The module creates a user-assigned identity and grants it Network Contributor on the VNet. |
| **BYO identity** | Set `aks_create_cluster_identity = false` and set `aks_cluster_identity_id` to your identity's resource ID. Pre-grant it Network Contributor on the VNet (and Private DNS Zone Contributor on the zone if using a custom DNS zone). |

These two options are **mutually exclusive** — setting both is rejected by a Terraform
`precondition`.

---

## Backing services — Private Endpoints

Postgres and Redis reach the cluster via **Private Endpoints**, not VNet injection or
public endpoints.

The module automatically creates:

| Service | Private DNS zone | VNet link |
|---------|-----------------|-----------|
| Azure Database for PostgreSQL Flexible Server | `privatelink.postgres.database.azure.com` | Linked to your VNet |
| Azure Cache for Redis (AMR) | `privatelink.redis.azure.net` | Linked to your VNet |

You do **not** pre-create these zones. The Postgres subnet must be a **regular subnet** —
it is NOT delegated to `Microsoft.DBforPostgreSQL/flexibleServers` (delegation was the old
VNet-injection model; the module now uses Private Endpoints exclusively).

**Caveat — centrally-managed zones:** if your platform team already manages
`privatelink.postgres.database.azure.com` or `privatelink.redis.azure.net` centrally and
links them to your VNet, applying this module will conflict (a VNet cannot link two zones
with the same name). Coordinate with your platform team before applying.

---

## Validate offline

Both roots ship with Terraform test cases. Run them without provisioning real Azure
resources:

```bash
terraform -chdir=modules/azure-private/infra test
terraform -chdir=modules/azure-private/bootstrap test
```

Requires Terraform >= 1.7.

---

## Quick start

```bash
# Phase 1 — Azure infra (run from anywhere)
cp modules/azure-private/infra/terraform.tfvars.example modules/azure-private/infra/terraform.tfvars
# Edit terraform.tfvars — fill in subscription_id, resource IDs, secrets
terraform -chdir=modules/azure-private/infra init
terraform -chdir=modules/azure-private/infra plan
terraform -chdir=modules/azure-private/infra apply

# Phase 2 — In-cluster bootstrap (run from the jumpbox inside the VNet)
# ssh azureuser@<jumpbox-public-ip>
terraform -chdir=modules/azure-private/bootstrap init
terraform -chdir=modules/azure-private/bootstrap apply \
  -var="subscription_id=<SUB>" \
  -var="resource_group_name=<RG>" \
  -var="identifier=<IDENTIFIER>"
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full runbook including prerequisites, the LangSmith
Helm install (Phase 4), and teardown order.
