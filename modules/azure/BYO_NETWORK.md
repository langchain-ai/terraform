# Bring-Your-Own Network & Private Networking — Prerequisites

This guide covers the **opt-in** flags for deploying LangSmith into **existing** Azure
network/resource-group infrastructure and for **hardening** the cluster's network
posture (private API server, firewall egress, Azure CNI Overlay).

> **All of these are off by default.** The standard [quickstart](README.md#quick-start)
> creates its own resource group, VNet, and a public cluster — none of this applies
> unless you explicitly set the flags below. Existing deployments re-plan to a no-op.

This is the "enterprise landing zone" path: you bring a resource group and a VNet that
already sits behind a firewall, and the AKS API server is private. The common bundle is
**BYO resource group + BYO VNet + userDefinedRouting + private API server**, optionally
with Azure CNI Overlay.

---

## The flags

| Flag | Default | What it does |
|------|---------|--------------|
| `create_resource_group` | `true` | Set `false` to deploy into an existing RG (`resource_group_name`). |
| `create_vnet` | `true` | Set `false` to deploy into an existing VNet (supply subnet IDs). |
| `aks_network_plugin_mode` | `""` (classic) | `"overlay"` enables Azure CNI Overlay (pods get IPs from `aks_pod_cidr`). |
| `aks_network_policy` | `"azure"` | `"calico"` or `"cilium"` (required for overlay; `cilium` recommended). |
| `aks_outbound_type` | `"loadBalancer"` | `"userDefinedRouting"` routes egress via your subnet's route table → firewall. |
| `aks_private_cluster_enabled` | `false` | `true` gives the API server a private endpoint (no public IP). |
| `aks_create_cluster_identity` | `false` | `true` creates a user-assigned control-plane identity + grants it Network Contributor on the VNet (recommended for BYO-VNet/UDR). |
| `aks_cluster_identity_id` | `""` | Bring an existing user-assigned control-plane identity (needed for a custom API-server private DNS zone). |

See [`infra/terraform.tfvars.hardened.example`](infra/terraform.tfvars.hardened.example)
for a complete worked configuration.

---

## General prerequisites

- **Terraform ≥ 1.5**, **azurerm ~> 4.0**, authenticated to the target subscription
  (`az login` + `az account set`).
- The Terraform principal needs the [standard RBAC](README.md#required-azure-rbac)
  (**Contributor** + **User Access Administrator**, or **Owner**) **plus**, when using a
  BYO VNet, **Network Contributor** on the existing VNet (or a custom role granting
  `Microsoft.Network/virtualNetworks/subnets/join/action`) so AKS, PostgreSQL, and Redis
  can join your subnets.
- The required Azure resource providers are registered (`make preflight` checks these).

---

## What you must pre-create (customer responsibilities)

Everything in this section must already **exist before `terraform apply`** — the module
**consumes** these, it does not create them. Only the rows for the flags you actually enable
apply. The deeper sections below explain each item; this is the at-a-glance checklist.

**Any BYO path**
- [ ] Auth + RBAC per [General prerequisites](#general-prerequisites) — including **Network
  Contributor on the VNet** when `create_vnet = false`.

**`create_resource_group = false`**
- [ ] An existing **resource group** (you have Contributor+; deployment region is taken from it).

**`create_vnet = false`** — an existing **VNet** plus the subnets you use:
- [ ] **AKS subnet** — with the **`Microsoft.Storage` + `Microsoft.KeyVault` service endpoints** enabled.
- [ ] **PostgreSQL subnet** — delegated to `Microsoft.DBforPostgreSQL/flexibleServers` (when `postgres_source = "external"`).
- [ ] **Redis subnet** — dedicated, no other resources (when `redis_source = "external"`).
- [ ] **AGIC subnet** — dedicated /24+ (when `ingress_controller = "agic"`).
- [ ] **Bastion subnet** (when `create_bastion = true`).
- [ ] Non-overlapping CIDRs: VNet vs `aks_service_cidr` vs (overlay) `aks_pod_cidr`.

**`aks_outbound_type = "userDefinedRouting"`**
- [ ] A **route table** associated with the AKS subnet, default route `0.0.0.0/0` → your firewall/NVA private IP.
- [ ] Firewall rules permitting the [required AKS egress](https://learn.microsoft.com/azure/aks/limit-egress-traffic).

**`aks_private_cluster_enabled = true`**
- [ ] An **apply host with VNet reachability** to the private API IP (bastion / peered / self-hosted runner) that can resolve the cluster's private DNS zone.
- [ ] If `aks_private_dns_zone_id = "None"`: your **own DNS resolution** for the API FQDN (keep public FQDN enabled).
- [ ] If using a **custom** private DNS zone: the zone (`privatelink.<region>.azmk8s.io`) **linked to your VNet**, plus a **user-assigned identity** (`aks_cluster_identity_id`) pre-granted **Private DNS Zone Contributor** (zone) + **Network Contributor** (VNet).
- [ ] **Custom DNS servers?** Conditional forwarders for the `privatelink.*` zones → `168.63.129.16`.

**The module creates these for you — do NOT pre-create them:**
- The AKS cluster, node pools, OIDC issuer; and (opt-in) the control-plane user-assigned identity + its VNet Network Contributor grant.
- The **PostgreSQL** and **Redis** private DNS zones (`privatelink.postgres.database.azure.com`, `privatelink.redis.azure.net`) and their VNet links.
- The **System** API-server private DNS zone (when `aks_private_dns_zone_id = ""`).
- Postgres, Redis, Blob, Key Vault, and the pod Workload Identity.

---

## BYO resource group (`create_resource_group = false`)

**Prerequisites**

- An existing resource group, and you have **Contributor** (or higher) on it.
- Set `resource_group_name` to its name. The deployment **region is inherited from the
  RG** — `location` only applies when Terraform creates the RG.

**Notes**

- All LangSmith resources are created **inside** your RG. Destroying the deployment does
  **not** delete the RG itself.
- AKS still auto-creates its own node resource group (`MC_<rg>_<cluster>_<region>`) — that
  is normal and separate from your RG.

---

## BYO VNet / subnet (`create_vnet = false`)

This is the most involved path — your VNet must be pre-wired to satisfy several AKS and
LangSmith requirements.

**Required inputs**

| Variable | When required |
|----------|---------------|
| `vnet_id` | always |
| `aks_subnet_id` | always |
| `postgres_subnet_id` | when `postgres_source = "external"` (default) |
| `redis_subnet_id` | when `redis_source = "external"` (default) |
| `agic_subnet_id` | when `ingress_controller = "agic"` |
| `bastion_subnet_id` | when `create_bastion = true` |

**Subnet requirements**

- **AKS subnet** must have the **`Microsoft.Storage` and `Microsoft.KeyVault` service
  endpoints** enabled. The Blob and Key Vault firewalls default-deny and allowlist the AKS
  subnet via these endpoints — **without them, pods cannot reach Blob Storage or Key
  Vault.** (The managed `networking` module adds these automatically; a BYO subnet must
  replicate them.)
- **PostgreSQL subnet** must be **delegated to
  `Microsoft.DBforPostgreSQL/flexibleServers`** and used by nothing else.
- **Redis subnet** must be a **dedicated** subnet (Azure Cache for Redis Premium
  requirement) — no other resources.
- **AGIC subnet** (if used) must be a dedicated **/24 or larger** subnet.

**Subnet sizing**

- **Classic Azure CNI (default):** pods draw IPs from the subnet. Size for
  `max_nodes × max_pods_per_node` (plus headroom). For the production defaults that is
  several hundred IPs.
- **Azure CNI Overlay:** pods draw from `aks_pod_cidr`, **not** the subnet — the AKS
  subnet only needs enough IPs for the **nodes**, so it can be much smaller.

**CIDR rules**

- `aks_service_cidr` and (in overlay) `aks_pod_cidr` must **not overlap** the VNet, each
  other, or any peered/on-prem range.

---

## Private DNS & private endpoints for the backing services

When you bring a VNet, the module still wires up private connectivity for PostgreSQL,
Redis, Blob, and Key Vault — you only supply the subnets. Three different mechanisms are
used:

| Service | How it connects | What the module creates (linked to **your** `vnet_id`) |
|---------|-----------------|---------------------------------------------------------|
| **PostgreSQL** | VNet injection into the delegated `postgres_subnet_id` | Private DNS zone `privatelink.postgres.database.azure.com`, linked to your VNet |
| **Redis (AMR)** | Private endpoint in `redis_subnet_id` | Private DNS zone `privatelink.redis.azure.net`, linked to your VNet (A-record auto-registered via the endpoint's DNS zone group) |
| **Blob + Key Vault** | **Service endpoints** on the AKS subnet (NOT private endpoints) | Nothing — relies on the `Microsoft.Storage` / `Microsoft.KeyVault` service endpoints you enable on the AKS subnet, plus each account's default-deny firewall allowlisting that subnet |

So with a BYO VNet you do **not** pre-create the Postgres/Redis private DNS zones — the
module creates them and links them to your VNet automatically. Two caveats:

- **Custom DNS servers (hub-spoke):** if your VNet uses custom DNS servers, resolution for
  those `privatelink.*` zones only works if your DNS forwards to Azure DNS (168.63.129.16).
  Add conditional forwarders for `privatelink.postgres.database.azure.com`,
  `privatelink.redis.azure.net` (and the AKS API-server zone) as needed.
- **Centrally-managed private DNS:** the module **always creates** these two zones. If your
  platform team centrally manages `privatelink.postgres…` / `privatelink.redis…` and already
  links them to the VNet, that conflicts — a VNet can't link two zones with the same name.
  There is currently no "bring-your-own private DNS zone" toggle for Postgres/Redis.

---

## Azure CNI Overlay (`aks_network_plugin_mode = "overlay"`)

**Prerequisites**

- Set `aks_network_policy` to **`"cilium"`** (recommended — Azure CNI Overlay powered by
  Cilium, eBPF dataplane) or **`"calico"`**. `"azure"` (NPM) is **not supported** with
  overlay; the module's validation rejects it.
- Linux node pools only (Cilium network policy is not available for Windows nodes).
- Set `aks_pod_cidr` to a private range that doesn't overlap the VNet / service CIDR /
  peered networks (default `10.244.0.0/16`).

**Notes**

- Overlay egress is SNAT'd to the node IP.
- **Immutable:** the cluster `network_profile` is `ForceNew` in the provider — switching an
  **existing** cluster to overlay forces cluster **recreation** through Terraform. Choose
  overlay at creation time for greenfield deployments.
- Microsoft is deprecating Azure NPM (Linux EOL 2028-09-30); Cilium is the long-term
  supported engine. See
  [AKS network policies](https://learn.microsoft.com/azure/aks/use-network-policies).

---

## userDefinedRouting egress (`aks_outbound_type = "userDefinedRouting"`)

**Prerequisites**

- **Requires `create_vnet = false`** (enforced) — AKS does not create or manage the route
  table; your existing subnet must already have one.
- The AKS subnet must have a **route table associated** with a default route
  (`0.0.0.0/0`) pointing to your **firewall / NVA private IP**.
- The firewall must **allow the required AKS egress** (control-plane FQDNs and ports). See
  [Control egress traffic for AKS](https://learn.microsoft.com/azure/aks/limit-egress-traffic).

**Notes**

- **Immutable:** changing `outbound_type` forces cluster recreation.
- Inbound ingress (NGINX/AGIC public LB) is unaffected — UDR only governs egress.

---

## Private API server (`aks_private_cluster_enabled = true`)

The API server endpoint gets a **private IP** with no public address (and, by default, no
public FQDN).

**⚠️ Apply-host requirement (most important)**

`terraform apply` runs the in-cluster bootstrap — namespace, secrets, cert-manager, KEDA,
and the ingress controller (NGINX) — through the `helm`/`kubernetes` providers, which
**connect to the API server during apply**. With a private API server you must run
`terraform apply` from a host that can both:

1. **Reach** the private API IP — i.e. it is **inside the VNet, peered to it, or
   connected via VPN/ExpressRoute** (DNS resolution alone is not enough), and
2. **Resolve** the cluster's private DNS zone.

Set **`create_bastion = true`** to provision an in-VNet jump host, or use a self-hosted
CI runner placed in/peered to the VNet.

**Other prerequisites**

- `aks_authorized_ip_ranges` must be **empty** (enforced) — an IP allowlist is mutually
  exclusive with a private cluster.
- The `aks_private_fqdn` output gives the private API endpoint once applied (its name lives
  under the `privatelink.<region>.azmk8s.io` zone).

### How the API-server private DNS zone is set up

When `aks_private_cluster_enabled = true`, AKS **always** creates a **private endpoint** for
the API server in the node resource group and resolves it through a private DNS zone named
`privatelink.<region>.azmk8s.io`. The `aks_private_dns_zone_id` variable controls **who owns
that zone and how it's linked** — three modes:

**1. `""` → `"System"` (default — fully automatic, zero setup)**

AKS creates the `privatelink.<region>.azmk8s.io` zone **in the node resource group
(`MC_*`)**, adds the API server's A record, and **auto-links the zone to the cluster's
VNet**. Any host in that VNet resolves the API server because Azure-provided DNS
(`168.63.129.16`) serves the linked zone. Works out of the box with the module's default
system-assigned identity — you create and link nothing.

> **Hub-spoke / custom-DNS caveat:** if the cluster's VNet uses **custom DNS servers**, the
> System zone resolves only if your DNS forwards `privatelink.<region>.azmk8s.io` to
> `168.63.129.16`. AKS auto-linking the System zone to the spoke also needs the
> control-plane identity to have **Network Contributor on the VNet** — which
> `aks_create_cluster_identity` grants (it scopes to the VNet, not just the subnet). With a
> *system-assigned* identity instead, ensure the Terraform principal can self-assign that
> during creation, or use `"None"` / a custom zone.

**2. `"None"` → you own DNS resolution**

AKS creates the private endpoint but **no DNS zone**. You are responsible for resolving the
API server's FQDN — typically a central DNS forwarder in hub-spoke, or your own private DNS
zone managed outside this module. Requires `aks_private_cluster_public_fqdn_enabled = true`
(Azure doesn't support `None` + a disabled public FQDN together).

**3. Custom private DNS zone resource ID → you bring and pre-wire the zone**

You pre-create a zone named exactly `privatelink.<region>.azmk8s.io` (or
`<subzone>.privatelink.<region>.azmk8s.io`), **link it to your VNet** (commonly the hub), and
AKS manages the A record inside it. This is the centralized-DNS hub-spoke pattern.
Requirements:

- A **user-assigned control-plane identity** via `aks_cluster_identity_id` (system-assigned
  is **not supported** with a custom zone). See [Control-plane identity](#control-plane-cluster-identity).
- That identity needs **Private DNS Zone Contributor** on the zone and **Network
  Contributor** on the VNet/subnet — **you grant these before apply** (the module does not,
  since the zone is yours and may live in another RG/subscription).
- The zone and private endpoint **can't be changed or deleted after the cluster is created**.

Whichever mode you pick, the **apply host must be able to resolve the chosen zone** (see the
apply-host requirement above): e.g. a bastion inside the VNet that's linked to the System
zone, or a forwarder that resolves your `None` / custom zone.

---

## Control-plane (cluster) identity

AKS uses a control-plane managed identity to manage network resources — including the
**subnet-join** action it needs for a BYO VNet, and DNS record management for a custom
API-server private DNS zone. Three modes:

| Mode | Set | Behavior |
|------|-----|----------|
| **System-assigned** (default) | neither flag | AKS creates and manages its own identity. Works for BYO-VNet + `System`/`None` DNS **provided the Terraform principal has User Access Administrator/Owner on the VNet** so AKS can self-assign the subnet permission during creation. |
| **Module-created user-assigned** | `aks_create_cluster_identity = true` | The module creates a user-assigned identity and grants it **Network Contributor on the VNet** *before* the cluster is created. VNet scope covers both subnet-join and the System private DNS zone link (the latter needs VNet-level permission in custom-DNS hub-spoke). **Recommended for BYO-VNet / UDR** — Azure recommends a user-assigned identity so the grant exists up front (avoids the system-assigned timing problem). |
| **Bring your own** | `aks_cluster_identity_id = "<uai-resource-id>"` | The module uses your identity as-is and assigns it **no** roles. **Required for a custom API-server private DNS zone** — pre-grant the identity **Private DNS Zone Contributor** on the zone and **Network Contributor** on the VNet/subnet yourself. This is the path when the zone lives in a hub / other subscription. |

Notes:

- The two flags are **mutually exclusive** (enforced).
- This is the **control-plane** identity — separate from the Workload Identity the module
  creates for pods to reach Blob / Key Vault.
- Switching an **existing** cluster between identity types is disruptive; choose at
  creation time.

---

## Validation guards (what's rejected at plan time)

The module fails fast with a clear message on the cross-field combinations that
Azure does **not** reject on its own:

| Rule |
|------|
| `aks_outbound_type = "userDefinedRouting"` requires `create_vnet = false`. |
| `aks_network_policy = "cilium"` requires `aks_network_plugin_mode = "overlay"`. |
| `aks_private_cluster_enabled = true` requires `aks_authorized_ip_ranges` to be empty. |
| Only one of `aks_create_cluster_identity` / `aks_cluster_identity_id` may be set. |

Other invalid inputs — an empty `resource_group_name` / `vnet_id` / subnet ID when the
matching `create_*` flag is `false`, or `aks_private_dns_zone_id = "None"` with the public
FQDN disabled — are rejected by Azure itself at plan/apply. The module relies on the
provider's own error there rather than duplicating it.

---

## Putting it together

1. Pre-create everything in
   [What you must pre-create](#what-you-must-pre-create-customer-responsibilities) for the
   flags you're enabling — RG, VNet/subnets (service endpoints + delegation), route table →
   firewall, apply host, and any custom DNS zone / identity.
2. Grant the Terraform principal the required RBAC (incl. Network Contributor on the VNet).
3. Copy [`infra/terraform.tfvars.hardened.example`](infra/terraform.tfvars.hardened.example)
   to `infra/terraform.tfvars` and fill in your IDs/names.
4. Run `terraform apply` **from a host with private API reachability** (e.g. with
   `create_bastion = true`).

> Tip: validate your configuration with no Azure calls using `terraform validate` and the
> offline test suite (`terraform -chdir=modules/azure/infra test`, needs Terraform ≥ 1.7).
