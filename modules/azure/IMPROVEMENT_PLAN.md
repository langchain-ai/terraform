# Azure Module Improvement Plan
# Bringing Azure to Feature Parity with AWS

**Reference:** AWS modules at `terraform/aws/infra/modules/`
**Context:** Internal standardization for the LangChain PS SA team

---

## Background

The AWS implementation is the current benchmark: it has a Bastion host, WAF, CloudTrail,
Route 53 DNS module, ALB, a Makefile, and automation scripts (preflight, deploy, init-values).
Azure has the core infra (AKS, Postgres, Redis, Blob, Key Vault, networking) but is missing
several production-hardening layers and the automation tooling that makes AWS deployments faster.

The existing `PLAN.md` covers Phase 1–4 internal refactoring (removing Helm from Terraform,
script-based deployment). This document covers the next layer: new modules, security hardening,
and automation parity.

---

## Current Azure Modules

| Module | What it does |
|--------|-------------|
| `networking` | VNet, subnets (AKS, Postgres, Redis), service endpoints |
| `k8s-cluster` | AKS, NGINX ingress, Workload Identity, node pools |
| `keyvault` | Key Vault, RBAC, soft-delete, LangSmith secrets storage |
| `postgres` | Azure PostgreSQL Flexible Server, private DNS, HA options |
| `redis` | Azure Cache for Redis Premium, private endpoint |
| `storage` | Blob storage, Workload Identity federation, TTL lifecycle rules |
| `k8s-bootstrap` | cert-manager, KEDA, namespace, SA, K8s infra secrets |

---

## Gap Summary vs AWS

| Category | AWS has | Azure missing |
|----------|---------|---------------|
| Security perimeter | WAF (WAFv2 on ALB) | Azure Application Gateway + WAF policy |
| Private cluster access | Bastion EC2 (SSM + SSH) | Bastion host (Azure Bastion or jump VM) |
| Audit logging | CloudTrail → S3 | Azure Monitor diagnostic settings |
| DNS management | Route 53 hosted zone + cert auto-provision | Azure DNS zone module |
| Workload Identity | IRSA centralized in EKS module | Scattered across only blob storage module |
| Multi-AZ | Configurable across EKS, RDS, ElastiCache | Hardcoded single AZ |
| Automation scripts | Makefile, preflight.sh, status.sh, init-values.sh | None |
| Deployment automation | deploy.sh with overlay support | In progress (PLAN.md) |

---

## Priority Tiers

### Tier 1 — Security (High Impact, Customer-Blocking)

These gaps block enterprise customers who require defense-in-depth or audit trails as
compliance requirements.

---

### Tier 2 — Operational Hardening (Medium Impact, SA Time Savings)

These reduce manual effort for SAs during customer engagements and post-deployment operations.

---

### Tier 3 — Feature Parity (Lower Urgency, Nice-to-Have)

These bring completeness but are not blocking any known customer scenarios.

---

## Tier 1 — Security Improvements

### 1.1 WAF Module (`modules/waf/`)

**Why:** AWS has WAFv2 protecting the ALB. Without WAF, the Azure NGINX ingress Load Balancer
is exposed to OWASP Top 10 attacks, Log4Shell payloads, and known malicious IPs.
Several enterprise customers (NFCU pattern) require WAF as a compliance prerequisite.

**What to build:**
- `azurerm_web_application_firewall_policy` resource
  - OWASP 3.2 managed rule set (CommonRuleSet equivalent)
  - Bot protection rule set (IpReputationList equivalent)
  - Custom blocking rules for known bad input patterns
- `azurerm_application_gateway` OR integrate WAF policy with existing NGINX LB
  - Option A: Azure Application Gateway v2 with WAF SKU (replaces NGINX ingress)
  - Option B: Azure Front Door WAF policy fronting the existing NGINX LB
  - Recommend Option B initially — non-breaking, can add to existing deployments

**Variables to add:**
```hcl
variable "create_waf" {
  type        = bool
  default     = false
  description = "Deploy Azure WAF policy on Front Door in front of the AKS ingress LB."
}

variable "waf_mode" {
  type        = string
  default     = "Prevention"
  description = "WAF mode: Detection (log only) or Prevention (block)."
}
```

**Files to create:**
- `terraform/azure/infra/modules/waf/main.tf`
- `terraform/azure/infra/modules/waf/variables.tf`
- `terraform/azure/infra/modules/waf/outputs.tf`
- Wire into `infra/main.tf` behind `create_waf` flag

**Reference:** `terraform/aws/infra/modules/waf/` — WAFv2 rule group pattern is directly
translatable to Azure managed rule groups.

---

### 1.2 Audit Logging Module (`modules/diagnostics/`)

**Why:** AWS has CloudTrail. Azure equivalent is diagnostic settings + Log Analytics Workspace.
Enterprise customers need an audit trail for control-plane operations (who created what, when).
Comparable to CloudTrail for AKS API server, Key Vault access, and Postgres logs.

**What to build:**
- `azurerm_log_analytics_workspace` — stores all diagnostic data
- `azurerm_monitor_diagnostic_setting` for:
  - AKS control plane (kube-audit, kube-apiserver, guard)
  - Key Vault (AuditEvent — who read/wrote secrets)
  - PostgreSQL (PostgreSQLLogs — slow queries, failed auth)
- Optional: `azurerm_storage_account` log archive bucket (long-term retention)
- Configurable retention days (default 90)

**Variables to add:**
```hcl
variable "create_diagnostics" {
  type        = bool
  default     = false
  description = "Deploy Azure Monitor Log Analytics and diagnostic settings for AKS, Key Vault, and Postgres."
}

variable "log_retention_days" {
  type        = number
  default     = 90
  description = "Log Analytics workspace retention period in days."
}
```

**Files to create:**
- `terraform/azure/infra/modules/diagnostics/main.tf`
- `terraform/azure/infra/modules/diagnostics/variables.tf`
- `terraform/azure/infra/modules/diagnostics/outputs.tf`
- Wire into `infra/main.tf` behind `create_diagnostics` flag

**Reference:** `terraform/aws/infra/modules/cloudtrail/` — structure is analogous. Follow the
same opt-in pattern (`create_cloudtrail = true` → `create_diagnostics = true`).

---

### 1.3 Centralize Workload Identity in k8s-cluster

**Why:** Currently Workload Identity federation (OIDC trust, federated credentials, RBAC role
assignments) is scattered inside the `storage` module only. Other modules that may need pod
identity (future Redis ESO, custom operators) have no centralized pattern to follow.

**What to do:**
- Move `azurerm_user_assigned_identity` to `k8s-cluster` module or a new `identity` module
- Export `client_id` and `principal_id` as outputs
- Let `storage`, `keyvault`, and future modules accept `workload_identity_client_id` and
  `workload_identity_principal_id` as inputs rather than creating their own identities
- Standardize service account annotation: `azure.workload.identity/client-id`
- Maintain backward compat for existing deployments via output aliasing

**Reference:** AWS IRSA is centralized in the EKS module (`eks/main.tf` → OIDC provider →
IRSA role). Azure should follow the same single-identity-per-cluster pattern.

---

## Tier 2 — Operational Hardening

### 2.1 Bastion Module (`modules/bastion/`)

**Why:** Private AKS clusters (no public API server) require jump host access for initial
`kubectl` and `helm` commands during SA engagements. AWS has an EC2 bastion with SSM
Session Manager (no SSH port exposed). Azure equivalent is Azure Bastion or a jump VM.

**What to build:**
- Option A: Azure Bastion Standard SKU (managed PaaS, no public IP on VM)
  - `azurerm_bastion_host` with Standard SKU (tunneling support for kubectl)
  - Requires dedicated `/27` subnet in the VNet (`AzureBastionSubnet`)
- Option B: Jump VM with Azure AD login (no SSH keys, `az ssh vm` auth)
  - `azurerm_linux_virtual_machine` with small SKU (Standard_B2s)
  - `azurerm_virtual_machine_extension` → AADSSHLoginForLinux
  - Pre-install: kubectl, helm, az CLI, jq via `custom_data`
  - RBAC: "Virtual Machine Administrator Login" role on VM resource

**Recommendation:** Option B first (cheaper, fewer moving parts), Option A for customers
requiring hardened private cluster access (no public VM IP at all).

**Variables to add:**
```hcl
variable "create_bastion" {
  type        = bool
  default     = false
  description = "Deploy a jump VM for private AKS cluster access."
}

variable "bastion_vm_size" {
  type        = string
  default     = "Standard_B2s"
  description = "VM SKU for the bastion host."
}
```

**Files to create:**
- `terraform/azure/infra/modules/bastion/main.tf`
- `terraform/azure/infra/modules/bastion/variables.tf`
- `terraform/azure/infra/modules/bastion/outputs.tf`

**Reference:** `terraform/aws/infra/modules/bastion/` — direct analog. Pre-install script
and IAM role pattern translate directly to Azure Custom Script Extension + RBAC.

---

### 2.2 DNS Module (`modules/dns/`)

**Why:** AWS has a Route 53 module that auto-provisions a hosted zone, creates an ACM cert
with DNS validation, and creates an alias record to the ALB. Azure SAs currently tell
customers to manage DNS manually or use cert-manager HTTP-01 challenges. An Azure DNS
module would enable self-contained, end-to-end TLS provisioning.

**What to build:**
- `azurerm_dns_zone` — public DNS zone for the LangSmith domain
- `azurerm_dns_a_record` — points to NGINX ingress public IP (from AKS LB)
- cert-manager DNS-01 challenge integration:
  - `azurerm_role_assignment` — cert-manager identity gets "DNS Zone Contributor"
  - Annotate ClusterIssuer to use Azure DNS-01 solver (removes HTTP-01 dependency)
- Optional: `azurerm_private_dns_zone` for private cluster scenarios

**Variables to add:**
```hcl
variable "create_dns_zone" {
  type        = bool
  default     = false
  description = "Create an Azure DNS zone and A record for the LangSmith domain."
}

variable "langsmith_domain" {
  type        = string
  default     = ""
  description = "Public DNS domain for LangSmith (e.g. langsmith.mycompany.com)."
}
```

**Files to create:**
- `terraform/azure/infra/modules/dns/main.tf`
- `terraform/azure/infra/modules/dns/variables.tf`
- `terraform/azure/infra/modules/dns/outputs.tf`

**Reference:** `terraform/aws/infra/modules/dns/` — same 3-resource pattern: zone, cert,
alias record. Replace Route 53 + ACM with Azure DNS + cert-manager DNS-01.

---

### 2.3 Makefile at `terraform/azure/Makefile`

**Why:** AWS has a comprehensive Makefile with targets for `init`, `plan`, `apply`,
`kubeconfig`, `deploy`, `status`, `destroy`. SAs working with Azure run these commands
manually every time. A Makefile reduces cognitive overhead and prevents common mistakes
(e.g. forgetting `source setup-env.sh` before `terraform apply`).

**What to build:**
```makefile
# Key targets to match AWS Makefile:
init         # terraform init
plan         # source setup-env.sh && terraform plan
apply        # source setup-env.sh && terraform apply
kubeconfig   # az aks get-credentials
deploy       # helm/scripts/deploy.sh (Pass 2)
status       # kubectl get pods -n langsmith
destroy      # terraform destroy
```

**File to create:** `terraform/azure/Makefile`

**Reference:** `terraform/aws/Makefile` — copy structure, replace AWS CLI calls with
`az` CLI equivalents.

---

### 2.4 Preflight Check Script (`infra/scripts/preflight.sh`)

**Why:** AWS has `infra/scripts/preflight.sh` that validates IAM permissions before
`terraform apply`. On Azure, SAs frequently hit RBAC errors mid-apply (missing
`Microsoft.Authorization/roleAssignments/write`, insufficient subscription scope).
A preflight script catches these before Terraform starts changing infrastructure.

**What to build:**
- Check Azure CLI is logged in and correct subscription is selected
- Validate required resource provider registrations:
  - `Microsoft.ContainerService` (AKS)
  - `Microsoft.DBforPostgreSQL`
  - `Microsoft.Cache`
  - `Microsoft.KeyVault`
  - `Microsoft.Storage`
- Check deployer has required roles:
  - Contributor on resource group (or subscription)
  - User Access Administrator (for RBAC role assignments)
- Validate `terraform.tfvars` exists and key fields are non-empty
- Check `az aks` version compatibility

**File to create:** `terraform/azure/infra/scripts/preflight.sh`

**Reference:** `terraform/aws/infra/scripts/preflight.sh` — replace IAM policy checks
with `az provider show` and `az role assignment list` commands.

---

### 2.5 Multi-AZ Support in Networking and Postgres

**Why:** AWS defaults to multi-AZ for all services. Azure SAs deploying for enterprise
customers (NFCU pattern) need HA Postgres and zone-redundant AKS. Currently these are
hardcoded to single-AZ.

**What to change:**

In `modules/networking/`:
- Add `availability_zones` variable (default `["1"]`, support `["1","2","3"]`)
- Pass AZ list to subnet creation for zone pinning

In `modules/postgres/`:
- Expose `high_availability` block properly with zone-redundant standby
- Add `geo_redundant_backup_enabled` variable (default false)

In `modules/k8s-cluster/`:
- Add `availability_zones` to default node pool
- Add `zone_balance` option for node pool distribution

**Variables to add across modules:**
```hcl
variable "availability_zones" {
  type        = list(string)
  default     = ["1"]
  description = "Azure availability zones to deploy into. Use [\"1\",\"2\",\"3\"] for zone-redundant HA."
}
```

---

## Tier 3 — Feature Parity

### 3.1 External Secrets Operator (ESO) for Key Vault

**Why:** AWS uses ESO to sync SSM Parameter Store secrets into Kubernetes secrets
automatically. Azure SAs use `setup-env.sh` + `kubectl create secret` (manual, one-time).
ESO for Azure Key Vault would allow secrets to auto-rotate when Key Vault values change,
without manual kubectl commands.

**What to build:**
- `helm_release.external_secrets` in `k8s-bootstrap` (same as AWS)
- `SecretStore` or `ClusterSecretStore` manifest targeting Azure Key Vault
- `ExternalSecret` manifests for each LangSmith secret (`langsmith-config-secret`)
- Wire Workload Identity for ESO pod to read Key Vault

**Effort:** Medium. AWS ESO IRSA pattern maps directly to Azure Workload Identity.

---

### 3.2 Status Script (`helm/scripts/status.sh`)

**Why:** AWS has `status.sh` that prints a consolidated pod/service/ingress summary.
SAs spend time running multiple kubectl commands during and after deployment.

**What to build:**
```bash
# Print: pods, services, ingress, LB IP, cert status, KEDA scaled objects
kubectl get pods,svc,ingress -n langsmith
kubectl get certificate -n langsmith
kubectl get scaledobject -n langsmith
```

**File to create:** `terraform/azure/helm/scripts/status.sh`

---

### 3.3 Storage Versioning and Customer-Managed Keys

**Why:** AWS S3 module supports optional versioning and SSE-KMS. Azure blob storage
supports both but the current module doesn't expose them.

**What to add to `modules/storage/`:**
- `versioning_enabled` variable (default false)
- `customer_managed_key_id` variable for Blob encryption with customer Key Vault key
- `azurerm_storage_account_customer_managed_key` resource (conditional on variable)

---

### 3.4 Network Policy Module Improvements

**Why:** AWS security groups are module-level and restrict inbound to VPC CIDR only.
Azure NSGs exist on subnets but the current networking module doesn't add granular
deny rules (e.g., deny all inbound to Postgres subnet except from AKS subnet).

**What to add to `modules/networking/`:**
- `azurerm_network_security_group` per subnet
- Rules: AKS subnet → Postgres/Redis subnets only; deny all other inbound
- Associate NSGs to subnets via `azurerm_subnet_network_security_group_association`

---

## Implementation Sequence

| Phase | Work | Modules Affected | Estimated PRs |
|-------|------|-----------------|---------------|
| **Phase A** | Centralize Workload Identity | `k8s-cluster`, `storage`, `keyvault` | 1 |
| **Phase B** | WAF module | `waf/` (new), `infra/main.tf` | 1 |
| **Phase C** | Diagnostics / audit logging | `diagnostics/` (new), `infra/main.tf` | 1 |
| **Phase D** | Bastion host | `bastion/` (new), `networking/`, `infra/main.tf` | 1 |
| **Phase E** | DNS module | `dns/` (new), `infra/main.tf` | 1 |
| **Phase F** | Makefile + preflight.sh | `Makefile` (new), `infra/scripts/` | 1 |
| **Phase G** | Multi-AZ support | `networking`, `postgres`, `k8s-cluster` | 1 |
| **Phase H** | ESO for Key Vault | `k8s-bootstrap` | 1 |
| **Phase I** | Status script + storage hardening | `helm/scripts/`, `storage/` | 1 |

**Prerequisites before starting Phase A:**
- Complete PLAN.md Phase 1–4 (Helm separated from Terraform)
- New `deploy.sh` overlay pattern in place

---

## New Module Directory Structure (target)

```
terraform/azure/infra/modules/
├── k8s-bootstrap/      # cert-manager, KEDA, namespace, SA, K8s infra secrets
├── k8s-cluster/        # AKS, Workload Identity (centralized), node pools
├── keyvault/           # Key Vault, RBAC, LangSmith secrets
├── networking/         # VNet, subnets, NSGs (improved)
├── postgres/           # PostgreSQL Flexible Server, private DNS, multi-AZ
├── redis/              # Azure Cache for Redis, private endpoint
├── storage/            # Blob, lifecycle rules, versioning
├── waf/                # (NEW) Azure WAF policy + Front Door or App Gateway
├── bastion/            # (NEW) Jump VM with Azure AD login
├── diagnostics/        # (NEW) Log Analytics, diagnostic settings
└── dns/                # (NEW) Azure DNS zone, cert-manager DNS-01 integration
```

---

## Reference Links

- AWS modules: `terraform/aws/infra/modules/`
- Azure modules: `terraform/azure/infra/modules/`
- Internal standardization plan: `terraform/azure/PLAN.md`
- NFCU enterprise reference: `terraform/azure/helm/values/use-cases/nfcu/`
- Support workspace patterns: `/Users/ddzmitry/Documents/Projects/support-workspace-setup/`
