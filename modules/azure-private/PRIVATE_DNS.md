# AKS API-server private DNS — how it works and what this Terraform does

When `private_cluster_enabled = true` (hardcoded in this module), the AKS **API server** gets a
**private IP** with no public endpoint. Reaching it requires DNS that resolves the API server's
FQDN (which lives under `privatelink.<region>.azmk8s.io`) to that private IP. This doc explains
who creates that zone, who links it, who manages the record — and exactly which of those steps
**our Terraform** performs versus which **AKS** (or you) performs.

> This is specifically about the **AKS API-server** zone. The **Postgres/Redis** private DNS
> zones are different and *are* created by this module — see [Backing-service zones](#dont-confuse-this-with-the-postgresredis-zones) at the bottom.

---

## The one line that selects the behavior

In `modules/k8s-cluster/main.tf` the cluster resource sets:

```hcl
private_cluster_enabled             = true
private_cluster_public_fqdn_enabled = var.private_cluster_public_fqdn_enabled
private_dns_zone_id                 = var.private_dns_zone_id != "" ? var.private_dns_zone_id : "System"
```

`var.private_dns_zone_id` comes from the root variable **`aks_private_dns_zone_id`**. Its value
picks one of three modes. **In every mode, AKS — not our Terraform — creates the API-server
private endpoint and manages the DNS A-record.** What differs is who owns the *zone* and who
*links* it to your VNet.

| `aks_private_dns_zone_id` | Mode | Who creates the **zone** | Who **links** it to the VNet | What **our Terraform** does |
|---|---|---|---|---|
| `""` (default) → `"System"` | **System** | **AKS** (in the node RG `MC_*`) | **AKS** (auto-links to the cluster VNet) | Selects `"System"`; provisions the control-plane identity + grants it Network Contributor on the VNet so AKS *can* create & link the zone. Creates **no zone**. |
| `"None"` | **None (BYO DNS)** | nobody (no zone) | n/a | Passes `"None"`. You own resolution. Requires `aks_private_cluster_public_fqdn_enabled = true` (Azure rejects `None` + disabled public FQDN). Creates **no zone**. |
| a zone **resource ID** | **Custom (BYO zone)** | **you**, before apply | **you**, before apply | Passes the ID to AKS so it manages the A-record inside *your* zone. Creates **no zone**, sets **no link**, grants **no role on the zone**. |

---

## Mode 1 — System (the default, zero setup)

This is what you get with `aks_private_dns_zone_id = ""` (the example tfvars default).

**AKS does:** creates a private endpoint for the API server in the node resource group
(`MC_<rg>_<cluster>_<region>`), creates the zone `privatelink.<region>.azmk8s.io` **in that
node RG**, adds the API server's A-record, and **auto-links the zone to the cluster's VNet**.
Any host in that VNet then resolves the API server because Azure-provided DNS (`168.63.129.16`)
serves the linked zone.

**Our Terraform does** (the part that makes the AKS auto-link succeed):

- Selects System mode (the `!= "" ? : "System"` expression above).
- Because `aks_create_cluster_identity` defaults to `true`, it creates a **user-assigned
  control-plane identity** and grants it **`Network Contributor` at the VNet scope**:
  ```hcl
  # cluster_vnet_id = the VNet that owns the AKS subnet (strip "/subnets/<name>" off subnet_id)
  cluster_vnet_id = join("/subnets/", slice(split("/subnets/", var.subnet_id), 0, 1))

  resource "azurerm_role_assignment" "cluster_identity_vnet" {
    scope                = local.cluster_vnet_id
    role_definition_name = "Network Contributor"
    principal_id         = azurerm_user_assigned_identity.cluster[0].principal_id
  }
  ```
  **Why VNet scope, not just the subnet:** the identity needs to do two things — *join the
  subnet* (`.../subnets/join/action`) **and** *link the System private DNS zone to the VNet*.
  The zone-link is a VNet-level operation, so a subnet-scoped grant is insufficient in
  custom-DNS hub-spoke topologies. Granting at the VNet covers both.
- Adds a 60-second `time_sleep` after the role assignment (RBAC propagation isn't instant) and
  makes the cluster `depends_on` it, so the grant exists before AKS tries to join the subnet and
  link the zone.

**Our Terraform does NOT** create the zone, the link, or the A-record — those are all AKS's job
in System mode.

> **System mode + a system-assigned identity:** if you set `aks_create_cluster_identity = false`
> *and* provide no `aks_cluster_identity_id`, the cluster falls back to a **system-assigned**
> identity and no VNet grant is created by this module — AKS then needs your Terraform principal
> to have rights to self-assign the subnet/zone permissions during creation. The module defaults
> to a module-created user-assigned identity precisely to avoid that timing problem.

## Mode 2 — None (you own DNS)

`aks_private_dns_zone_id = "None"`. AKS creates the private endpoint but **no zone and no
record**. You are responsible for resolving the API FQDN — typically a central DNS forwarder in
a hub. Azure requires `aks_private_cluster_public_fqdn_enabled = true` here. Our Terraform only
passes `"None"`; it creates nothing DNS-related.

## Mode 3 — Custom zone (centralized hub DNS)

`aks_private_dns_zone_id = "/subscriptions/.../privateDnsZones/privatelink.<region>.azmk8s.io"`.
This is the hub-spoke pattern where a platform team owns the zone centrally.

**You must, before apply:**
- Pre-create a zone named **exactly** `privatelink.<region>.azmk8s.io` (or
  `<subzone>.privatelink.<region>.azmk8s.io`) and **link it to your VNet** (commonly the hub).
- Use a **BYO control-plane identity**: set `aks_cluster_identity_id` (and leave
  `aks_create_cluster_identity = false` — they're mutually exclusive, enforced by a validation).
- **Pre-grant that identity** `Private DNS Zone Contributor` on the zone **and** `Network
  Contributor` on the VNet/subnet.

**Our Terraform does:** pass the zone ID to AKS (so AKS manages the A-record in your zone) and
use your BYO identity. It does **not** create the zone, link it, or grant `Private DNS Zone
Contributor` — the zone is yours and may live in another RG/subscription, so those grants are
your responsibility. (A system-assigned identity is **not supported** with a custom zone.)

---

## Resolving the zone from the apply host (every mode)

`terraform apply` runs the in-cluster bootstrap (Helm/kubernetes providers) against the private
API server *during apply*, so the apply host must **resolve and reach** the chosen zone:

- **System:** a host in the **linked VNet** (e.g. the jumpbox this module provisions, or a
  peered runner) resolves it automatically via `168.63.129.16`.
- **Custom DNS servers on the VNet:** Azure-provided DNS isn't in the path, so add a
  **conditional forwarder** for `privatelink.<region>.azmk8s.io` → `168.63.129.16` (the same
  applies to the Postgres/Redis privatelink zones).
- **None / Custom:** you must provide resolution (your forwarder / your zone link).

The applied private endpoint FQDN is exposed as the **`aks_private_fqdn`** output.

---

## Does the control-plane identity have the right permissions?

Short answer: **for the default System mode, yes** — and **for a custom zone, the module
deliberately does not grant enough, because that grant is yours to make.** Per Microsoft's
[private-cluster docs](https://learn.microsoft.com/azure/aks/private-clusters):

**System mode (module-created identity) — sufficient.**
- The only role the cluster identity needs against *your* network is **Network Contributor on
  the VNet**, which this module grants. Microsoft states that with the default System zone, "AKS
  tries to link the zone directly to the spoke VNet… this action can fail if the cluster's
  managed identity lacks **Network Contributor** on the spoke VNet." Our VNet-scoped grant is
  exactly that permission (and it also covers subnet-join).
- The zone itself is created in the **node resource group (`MC_*`)**, where AKS auto-grants the
  control-plane identity **Contributor** as part of provisioning — so zone creation + the
  A-record are covered without anything from us.
- You do **not** need `Private DNS Zone Contributor` for System mode.

**Custom zone mode — Network Contributor alone is NOT enough.**
- Microsoft requires the user-assigned identity to hold **both `Private DNS Zone Contributor`
  (on the custom zone) and `Network Contributor` (on the VNet).** Missing the zone role produces
  `CustomPrivateDNSZoneMissingPermissionError`.
- This module does **not** create that zone role assignment — the zone is yours (often in a hub
  / another subscription). You must pre-grant both roles to the identity you pass via
  `aks_cluster_identity_id`. (System-assigned identities are not supported with a custom zone.)

**RBAC propagation caveat.** The module adds a 60-second `time_sleep` after its Network
Contributor grant, which is enough in practice. Azure notes propagation can occasionally take
**up to 60 minutes**; for a custom BYO identity, make the grants well before `apply`.

---

## Summary — what our Terraform creates for the AKS API zone

| Thing | System (default) | None | Custom |
|---|---|---|---|
| Private endpoint for API server | AKS | AKS | AKS |
| The `privatelink.<region>.azmk8s.io` **zone** | AKS | — | **you** |
| **VNet link** to that zone | AKS (auto) | — | **you** |
| API server **A-record** | AKS | — | AKS |
| Control-plane **identity** | **our TF** (user-assigned) | our TF | **you** (BYO) |
| **Network Contributor** on the VNet | **our TF** | our TF | **you** |
| **Private DNS Zone Contributor** on the zone | n/a | n/a | **you** |

In short: for the default System mode, **our Terraform's job is the identity + the VNet
Network-Contributor grant** (so AKS can create and link the zone); **AKS creates and manages the
zone itself**. We never create the AKS API-server zone in any mode.

---

## Don't confuse this with the Postgres/Redis zones

Unlike the API-server zone, this module **does** create the backing-service private DNS zones and
link them to your VNet (in the `postgres`/`redis` sub-modules):

- `azurerm_private_dns_zone "privatelink.postgres.database.azure.com"` + a
  `azurerm_private_dns_zone_virtual_network_link` to your VNet, with the Postgres **Private
  Endpoint** registering its A-record via a `private_dns_zone_group`.
- `azurerm_private_dns_zone "privatelink.redis.azure.net"` + link, same pattern for Redis.

**Caveat:** because the module always creates these two zones, if a platform team already manages
them centrally and links them to your VNet, you get a conflict (a VNet can't link two zones of
the same name). There is no BYO-zone toggle for Postgres/Redis yet — see the README caveat.
