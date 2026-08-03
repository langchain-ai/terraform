# LangSmith on Azure — Deployment Guide

Self-hosted LangSmith on Azure Kubernetes Service (AKS), managed with Terraform.

> **Deploy from a release tag, not `main`.** Check out the latest `v0.15.*` tag before deploying (don't hardcode a patch): `git fetch --tags && git checkout "$(git tag -l 'v0.15.*' --sort=-v:refname | head -1)"`. Tags pin the LangSmith chart line (`~0.15.1` = latest `0.15.x`, never `0.16`). See [Versioning and releases](../../README.md#versioning-and-releases).

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on Azure. Deployment is split into five passes:

| Pass | What | How | Time |
|------|------|-----|------|
| **Pass 1** | AKS cluster, Postgres, Redis, Blob, Key Vault, cert-manager, KEDA | `make apply` | ~15–20 min |
| **Pass 1.5** | Cluster credentials + K8s secrets from Key Vault | `make kubeconfig && make k8s-secrets` | ~2 min |
| **Pass 2** | LangSmith Helm chart (~25 pods production) — **Helm path** | `make init-values` → `make deploy` | ~10 min |
| **Pass 2** | LangSmith Helm chart (~25 pods production) — **Terraform path** | `make init-app` → `make apply-app` | ~10 min |
| **Pass 3** | + LangSmith Deployments (`enable_deployments = true`) — scale nodes to min 5 first | `make apply && make init-values && make deploy` | ~5 min |
| **Pass 4** | Fleet (`enable_fleet = true`) — Agent Builder (`enable_agent_builder = true`) is the deprecated legacy path | `make init-values && make deploy` | ~5 min |
| **Pass 5** | Insights + Polly (`enable_insights = true`, `enable_polly = true`) | `make init-values && make deploy` | ~5 min |

A [Makefile](Makefile) wraps all commands — run `make help` to see available targets.

### Two Pass 2 paths

| Path | When to use |
|------|-------------|
| **Helm path** (`make deploy`) | Default. Shell script with interactive output, kubeconfig refresh, pre-flight checks, and post-deploy status. Best for first-time deploys and day-2 re-deploys. |
| **Terraform path** (`make apply-app`) | Declarative. Helm release + K8s secrets + Workload Identity SA managed in Terraform state. Best for GitOps workflows, CI/CD pipelines, and teams that want Helm in state. |

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Light** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
| **Production** | Azure DB for PostgreSQL (private) | Azure Cache for Redis (private) | [LangChain Managed](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) | Scalable / persistent |

> **Blob storage is always required.** Trace payloads must go to Azure Blob — never to ClickHouse.
>
> **In-cluster ClickHouse is for dev/POC only.** It runs as a single pod with no replication or backups. For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

### Deploying onto an existing AKS cluster

Set `create_cluster = false` to attach to a cluster the customer already runs. Terraform still provisions Key Vault, Blob storage, Managed Identities, and the Workload Identity federated credentials — it reads the cluster instead of creating it, and never modifies or destroys it.

```hcl
create_cluster                       = false
existing_cluster_name                = "customer-aks-cluster"
existing_cluster_resource_group_name = "customer-platform-rg"  # omit if same RG

# Point the supporting resources at the cluster's own network.
create_vnet        = false
aks_subnet_id      = "/subscriptions/.../virtualNetworks/<vnet>/subnets/<aks-subnet>"
postgres_subnet_id = "/subscriptions/.../virtualNetworks/<vnet>/subnets/<pg-subnet>"
redis_subnet_id    = "/subscriptions/.../virtualNetworks/<vnet>/subnets/<redis-subnet>"
```

Cluster prerequisites — verify before applying:

```bash
az aks show --name <cluster> --resource-group <rg> \
  --query "{oidc:oidcIssuerProfile.enabled, wi:securityProfile.workloadIdentity.enabled, localAccounts:disableLocalAccounts}"
```

| Requirement | Why | Fix |
|---|---|---|
| OIDC issuer + Workload Identity enabled | Federated credentials trust the cluster's OIDC issuer; without it pods can't reach Blob or Key Vault | `az aks update -n <cluster> -g <rg> --enable-oidc-issuer --enable-workload-identity` (in-place, no recreate) |
| Local accounts **not** disabled | The Helm/Kubernetes providers authenticate with the cluster's `kube_config`, which Azure returns empty on AAD-only clusters | Re-enable, or deploy Pass 2+ out-of-band with a `kubelogin` kubeconfig |
| API server reachable from the apply host | Pass 1 installs cert-manager and KEDA into the cluster | Add the apply host's egress CIDR to the cluster's authorized IP ranges |

`aks_subnet_id` must be a subnet the existing cluster already runs nodes in. It's what the Blob and Key Vault firewalls allowlist and the only subnet an added node pool can join, so a mismatch leaves pods unable to read secrets or write traces. Terraform checks it against the cluster's agent pools and fails the plan with the list of subnets it accepts.

`infra/scripts/quickstart.sh` reads that subnet, its VNet, and the cluster's region off the cluster once you name it, so those three are confirmed rather than pasted. When the cluster's pools span more than one subnet it lists them and asks which one LangSmith's pods run in. Anything Azure won't answer — a pool on an AKS-managed VNet, an expired login — falls back to the prompts.

Terraform adds no node pools to an existing cluster by default, so confirm it already has capacity for ClickHouse and LangGraph workloads. ClickHouse is one pod and nothing pins it to a pool, so a single node has to hold its whole request: 2 vCPU / 8 GiB under the default `production` sizing profile, 4 vCPU / 16 GiB under `production-large`. Run `bash infra/scripts/preflight.sh` to check that against the live nodes, since allocatable capacity is lower than the VM size suggests — a `Standard_D4s_v3` advertises 4 vCPU / 16 GiB and allocates 3860m / 14.3 GiB. Set `existing_cluster_node_pools_managed = true` to have Terraform add the `large` pool (`Standard_D16s_v3`) itself; the AKS subnet capacity check then counts it, and the subnet needs room for `(max_count + 1) × 31` addresses. Terraform never adopts pools that already exist either way, so a cluster whose pools you keep is untouched.

That subnet also needs the `Microsoft.Storage` and `Microsoft.KeyVault` service endpoints. The Blob and Key Vault firewalls allowlist it by subnet ID, which only matches when a service endpoint keeps the traffic on the Azure backbone instead of NATing it out to a public IP. Without them Azure rejects the firewall rule and the apply fails naming the subnet. Terraform enables both on the subnets it creates, so this applies to any `create_vnet = false` deployment, not only an existing cluster:

```bash
# The update replaces the endpoint list rather than appending, so check first
# and repeat anything already there.
az network vnet subnet show --ids <aks-subnet-id> --query "serviceEndpoints[].service"

az network vnet subnet update --ids <aks-subnet-id> \
  --service-endpoints Microsoft.Storage Microsoft.KeyVault
```

Terraform also warns when `location` doesn't match the cluster's region, since Key Vault, Blob, PostgreSQL, and Redis are created in `location` and pod traffic to them would cross regions.

These variables shape the cluster itself, so Terraform reads and ignores them once it no longer owns the cluster — change them on the cluster directly:

- `default_node_pool_vm_size`, `default_node_pool_min_count`, `default_node_pool_max_count`, `default_node_pool_max_pods`
- `aks_service_cidr`, `aks_dns_service_ip`
- `aks_authorized_ip_ranges`
- `availability_zones`, for the cluster only — PostgreSQL and the bastion still use it

The `agic` and `istio-addon` ingress modes require `create_cluster = true` — both configure AKS-managed add-ons that only apply to a Terraform-owned cluster. Use `nginx`, `istio`, or `envoy-gateway` instead.

---

## Prerequisites

### Required tools

```bash
# Azure CLI (>= 2.50)
brew install azure-cli
az --version

# Terraform (>= 1.5)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version

# kubectl
brew install kubectl
kubectl version --client

# Helm (>= 3.12)
brew install helm
helm version
```

### Required Azure RBAC

The identity running Terraform needs the following roles on the subscription:

| Role | Purpose |
|------|---------|
| `Contributor` | Create and manage all Azure resources |
| `User Access Administrator` | Create role assignments for Key Vault, Blob, cert-manager managed identities |

Owner includes both. Contributor alone is insufficient (role assignments require UAA).

### Authenticate

```bash
az login
az account set --subscription <your-subscription-id>
az account show   # verify correct subscription
```

---

## Quick Start

```bash
cd terraform/azure

# 1. Generate terraform.tfvars (interactive wizard — subscription, region, ingress, TLS, sizing)
make quickstart

# Prefer editing manually? Copy the example instead:
# cp infra/terraform.tfvars.example infra/terraform.tfvars
# vi infra/terraform.tfvars

# 2. Bootstrap secrets (prompts on first run, reads from Key Vault on repeat)
make setup-env

# 3. Check prerequisites
make preflight

# 4. Deploy infrastructure (~15–20 min)
# Note: make plan will fail on a fresh deploy (no cluster yet for kubernetes_manifest).
# Skip plan and run apply directly — it handles the ordering in three stages.
make init
make apply

# 5. Get cluster credentials + K8s secrets
make kubeconfig
make k8s-secrets

# 6. Generate Helm values from Terraform outputs
make init-values

# 7. Deploy LangSmith (~10 min) — Helm path
make deploy

# 8. Check status
make status
```

Or run everything after `make apply` in one shot:

```bash
make deploy-all   # kubeconfig → k8s-secrets → init-values → deploy
```

**Terraform Helm path** (alternative to steps 5–7 above):

```bash
cp app/terraform.tfvars.example app/terraform.tfvars
vi app/terraform.tfvars         # set admin_email at minimum
make init-app                   # pulls infra outputs → app/infra.auto.tfvars.json + tf init
make apply-app                  # helm release + K8s secrets + WI service account via Terraform
```

Or end-to-end with Terraform:

```bash
make deploy-all-tf   # apply → init-values → init-app → apply-app
```

For the full copy-paste guide with expected outputs and gotchas, see [QUICK_REFERENCE.md](QUICK_REFERENCE.md).
For demo/POC (all in-cluster DBs), see [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md).

### Naming your deployment

One variable names the deployment. `name_prefix` is appended to every resource
name and doubles as the `environment` tag, so `name_prefix = "prod"` gives
`langsmith-rg-prod`, `langsmith-aks-prod`, `langsmith-kv-prod` and tags
everything `environment = prod`. Terraform inserts the separating hyphen, so
write `prod`, not `-prod`.

Set `environment` explicitly only when the tag needs to differ from the
deployment name, e.g. `name_prefix = "prod-eastus"` with `environment = "prod"`.

**Upgrading from a release that used `identifier`:** rename the variable and keep
the value. `identifier = "-prod"` becomes `name_prefix = "prod"`; the leading
hyphen is now optional, so `"-prod"` also works. Every resource name is
unchanged, so `terraform plan` should report no changes to naming. Leaving
`identifier` in `terraform.tfvars` fails the plan with a message pointing here
rather than silently renaming your resources.

The `environment` tag does change. It used to default to `dev` and accept only
`dev`, `staging`, or `prod`; it now falls back to the deployment name and takes
any value. A deployment that set `identifier = "-prod"` and never set
`environment` re-tags from `dev` to `prod` on the next apply, and one named
`myco` tags `environment = myco`. Terraform updates tags in place, so nothing is
replaced, but cost allocation and Azure Policy rules keyed on the old value stop
matching. Set `environment = "dev"` explicitly to keep the old tag.

---

## Deployment Passes

| Pass | What | Make target |
|------|------|-------------|
| **1** | AKS + Postgres + Redis + Blob + Key Vault + cert-manager + KEDA + ClusterIssuer | `make apply` |
| **1.5** | Cluster credentials + K8s secrets from Key Vault | `make kubeconfig && make k8s-secrets` |
| **2 (Helm)** | LangSmith Helm (17 pods) via shell scripts | `make init-values && make deploy` |
| **2 (TF)** | LangSmith Helm via Terraform — secrets + SA + Helm release in state | `make init-app && make apply-app` |
| **3** | + LangSmith Deployments (`enable_deployments = true`) — bump `min_count` to 5 first | `make apply && make init-values && make deploy` |
| **4** | + Fleet (`enable_fleet = true`) — or the deprecated Agent Builder (`enable_agent_builder = true`) | `make init-values && make deploy` |
| **5** | + Insights + Polly (`enable_insights = true`, `enable_polly = true`) | `make init-values && make deploy` |

---

## Ingress Controllers

Set `ingress_controller` in `terraform.tfvars` before `make apply`. See [INGRESS_CONTROLLERS.md](INGRESS_CONTROLLERS.md) for the full TLS compatibility matrix and per-controller setup guide.

| Value | What Terraform installs | Best for |
|-------|------------------------|----------|
| `nginx` **(default)** | `ingress-nginx` Helm chart → Azure LB | Standard deployments. Simplest setup. Use this for quickstart. |
| `istio-addon` | AKS Service Mesh add-on (Azure-managed Istio) | Azure-managed Istio mesh, multi-dataplane, service-to-service mTLS. |
| `istio` | `istio-base` + `istiod` + `istio-ingressgateway` Helm charts | Self-managed Istio. Full mesh + sidecar injection. |
| `agic` | Azure Application Gateway v2 + AGIC Helm chart | Enterprise Azure. Native L7 WAF. HTTP-only or dns01 + custom domain. |
| `envoy-gateway` | `gateway-helm` OCI chart — Kubernetes Gateway API | Gateway API-native. Modern alternative to Ingress. |

---

## DNS + TLS

`dns_label` gives you a free Azure subdomain — `<label>.<region>.cloudapp.azure.com` — with no domain registration or DNS zone needed. `deploy.sh` annotates the correct LB service automatically.

**Quickstart default (HTTP, zero setup):**
```hcl
dns_label              = "langsmith-prod"
tls_certificate_source = "none"
```

**Add HTTPS with Let's Encrypt (nginx only — HTTP-01 requires an IngressClass):**
```hcl
dns_label              = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"
```

**Custom domain + DNS-01 (all controllers, works behind firewalls) — Validated ✅:**
```hcl
langsmith_domain       = "langsmith.mycompany.com"
tls_certificate_source = "dns01"
letsencrypt_email      = "you@example.com"
create_dns_zone        = true
# After deploy: add ingress_ip = "<lb-ip>" and re-run make apply (creates A record)
```

**dns01 flow:**
1. `make apply` → Terraform creates Azure DNS zone, outputs 4 nameservers
2. At your registrar: add NS records for the subdomain pointing to those 4 nameservers
3. Verify: `dig NS langsmith.mycompany.com @8.8.8.8`
4. `make deploy` → cert-manager issues cert via DNS-01 automatically (Workload Identity writes TXT record to Azure DNS)
5. Get LB IP → add `ingress_ip = "<ip>"` to `terraform.tfvars` → `make apply` (creates A record)
6. `make status` shows exactly what NS and A records to add at each stage

> **Why NS records, not CNAME:** cert-manager must *write* TXT records to the zone to prove ownership.
> That requires Azure DNS to be authoritative for the subdomain — NS delegation grants that authority.
> A CNAME only aliases traffic and does not transfer DNS authority; the DNS-01 challenge will fail.

> ⚠️ **`letsencrypt` (HTTP-01) only works with `nginx`, `istio` (self-managed), and `envoy-gateway`.**
> `istio-addon` and `agic` do not create an IngressClass, so the ACME solver cannot receive traffic.
> For those controllers, use `dns01` with a custom domain, or `none` for HTTP-only.
>
> See [INGRESS_CONTROLLERS.md](INGRESS_CONTROLLERS.md) for the full compatibility matrix and validated paths.

---

## Command Glossary

All commands run from `terraform/azure/`. Run `make help` to see the list at any time.

---

### `make quickstart` — Interactive setup wizard
**Script:** `infra/scripts/quickstart.sh`

Guided 10-section questionnaire that generates `infra/terraform.tfvars` from scratch. Mirrors the AWS quickstart experience.

- Sections: profile → subscription/naming → networking → AKS sizing → ingress controller → DNS/TLS → backend services → Key Vault → sizing profile → security add-ons
- Each section has explanatory context (`_hint` lines) to guide the right decision — cost estimates, compatibility notes, trade-offs
- Between sections: `Enter` continues, `b` goes back a section, `r` jumps to the review summary, `q` saves and quits
- After all sections: shows a full summary table and lets you re-run any section by number before writing the file (no need to restart from scratch)
- Answers are checkpointed to `infra/.quickstart-state` after every section, so quitting or losing the terminal costs at most the section you were on. The next run offers to resume, and every prompt is prefilled with your previous answer. The checkpoint is deleted once `terraform.tfvars` is written
- Re-running against an existing `terraform.tfvars` offers to load its values as answers, so you can change one setting without retyping the rest
- Auto-detects Azure subscription ID from `az account show`
- Validates deployment name format (`prod`, `staging`, `myco`)
- Supports all 5 ingress options: `nginx`, `istio-addon`, `istio`, `agic`, `envoy-gateway`
- Incompatibility warnings for `istio-addon + letsencrypt` and `agic + letsencrypt` with option to go back
- Prints a Next Steps summary with exact commands, including dns01 NS delegation steps when applicable

> **Run this first** on a new deployment. After it completes, run `source infra/scripts/setup-env.sh` to set up secrets.

---

### `make test-quickstart` — Unit tests for the wizard's resume layer
**Script:** `infra/scripts/test-quickstart-state.sh`

Exercises the checkpoint round-trip, the `_STATE_KEYS` whitelist that guards it, and seeding the wizard from an existing `terraform.tfvars`. Runs in a temp directory with no Azure calls and no prompts, so it is safe to run anywhere; your own `terraform.tfvars` is never read or written.

One check is worth knowing about when you rename a wizard variable: `_load_state` silently drops any key missing from `_STATE_KEYS`, so a rename that lands in `_load_tfvars` but not in the whitelist loses that answer on resume with no error. The test scrapes every variable `_load_tfvars` assigns and fails if one is not whitelisted.

---

### `make keyvault` — Key Vault secret manager
**Script:** `infra/scripts/manage-keyvault.sh`

Interactive menu and non-interactive CLI for managing LangSmith secrets in Azure Key Vault, without re-running `setup-env.sh`.

**Interactive mode (default):** `make keyvault` — presents a numbered menu.

**Non-interactive mode:**
```bash
make keyvault list                                          # list all secrets with timestamps
make keyvault get langsmith-license-key                     # read a secret
make keyvault set langsmith-admin-password 'NewP@ss!'       # update a secret
make keyvault validate                                      # check all required secrets exist
make keyvault diff                                          # compare KV vs K8s secret
make keyvault delete langsmith-deployments-encryption-key   # soft-delete (recoverable 90d)
```

Key behaviors:
- Resolves Key Vault name from `terraform output keyvault_name` → falls back to `langsmith-kv-{name_prefix}`
- `validate` — checks all 4 required secrets exist and are non-empty; validates admin password symbol requirement
- `diff` — compares Key Vault values vs `langsmith-config-secret` K8s secret key-by-key
- Warns on `langsmith-api-key-salt` and `langsmith-jwt-secret` (stable secrets — changing them invalidates all API keys / sessions)
- `delete` requires typing the full secret name for stable secrets, `y/N` for others
- After `set`, reminds to run `make k8s-secrets` to sync to K8s

---

### `make setup-env` — Bootstrap secrets
**Script:** `infra/scripts/setup-env.sh`

Collects all sensitive values and writes them to `infra/secrets.auto.tfvars` (gitignored, chmod 600). Terraform picks this file up automatically — no shell exports needed.

- Derives the Key Vault name from `name_prefix` in `terraform.tfvars` (e.g. `langsmith-kv-demo`)
- **First run:** prompts for PostgreSQL password, LangSmith license key, admin password, and admin email
- **Subsequent runs:** reads all values silently from Azure Key Vault — no prompts
- Stable secrets (API key salt, JWT secret, 4 Fernet encryption keys): reads from Key Vault → falls back to local dot-files → generates fresh if neither exists
- **Read-only against Key Vault** — never writes to KV directly. Terraform is the sole Key Vault writer; `setup-env.sh` only reads from it

> Run this before `make plan` or `make apply`. Re-run any time to rotate credentials.

---

### `make preflight` — Pre-flight validation
**Script:** `infra/scripts/preflight.sh`

Catches the most common problems before you spend 20 minutes on a failing `terraform apply`.

- Checks `az` CLI version and confirms you are logged in
- Prints the active subscription — prompts you to verify it is correct
- Validates 11 required Azure resource providers are registered (`Microsoft.ContainerService`, `Microsoft.DBforPostgreSQL`, `Microsoft.Cache`, `Microsoft.KeyVault`, `Microsoft.Storage`, and others)
- Checks RBAC: requires **Contributor** + **User Access Administrator** (or **Owner**) at subscription scope — needed for role assignments in the Key Vault, storage, and WAF modules
- Verifies `terraform.tfvars` exists with `location` and `subscription_id` set
- Verifies `secrets.auto.tfvars` exists and has a non-empty `langsmith_license_key`
- Checks that `terraform`, `kubectl`, and `helm` binaries are on PATH

> Safe to run at any time with no side effects.

---

### `make init` — Terraform init
Runs `terraform init` in `infra/`. Downloads the AzureRM provider, initializes the backend, and updates module sources. Required once per fresh clone and after any provider version change.

---

### `make plan` — Terraform plan
Runs `terraform plan` in `infra/`. Auto-runs `setup-env.sh` first if `secrets.auto.tfvars` is missing. Prints every resource that will be created, changed, or destroyed — no changes are made. Review this output before `make apply`.

---

### `make apply` — Provision Azure infrastructure
Runs `terraform apply -auto-approve` in `infra/`. Auto-runs `setup-env.sh` if needed. Creates all Azure resources (~15–20 min on first run):

- VNet + subnets (AKS, Postgres, Redis) + private DNS zones
- AKS cluster + node pools + OIDC issuer + managed identity + Workload Identity federated credentials
- Azure DB for PostgreSQL Flexible Server (if `postgres_source = "external"`)
- Azure Cache for Redis Premium (if `redis_source = "external"`)
- Azure Blob storage account + container + managed identity
- Azure Key Vault (RBAC mode, soft-delete) + all 10 application secrets
- cert-manager, KEDA, ingress controller (NGINX / Istio / AGIC / Envoy Gateway — based on `ingress_controller` in tfvars)
- For `agic`: Application Gateway v2 + public IP + AGIC managed identity + Contributor/Reader role assignments + AGIC Helm chart
- For `envoy-gateway`: `envoyproxy/gateway-helm` in `envoy-gateway-system` namespace
- `langsmith` namespace + `langsmith-sa` service account

---

### `make destroy` — Destroy Azure infrastructure
Runs `terraform destroy` in `infra/`. Permanently deletes all Azure resources. **Run `make uninstall` first** — if active LoadBalancer services remain, the cluster cannot be deleted and Terraform will timeout.

---

### `make destroy-force` — Destroy without confirmation prompt
Runs `terraform destroy -auto-approve` in `infra/`. Same as `make destroy` but skips the interactive "yes" confirmation — useful in non-interactive shells or CI. **Run `make uninstall` first.**

---

### `make clean` — Remove generated local files
**Script:** `infra/scripts/clean.sh`

Prompts for confirmation, then removes all generated and sensitive local files. Safe to run after a full teardown.

- Removes `infra/terraform.tfvars` and `infra/secrets.auto.tfvars`
- Removes temporary dot-files written by `setup-env.sh` (`.api_key_salt`, `.jwt_secret`, `.deployments_key`, etc.)
- Removes `infra/terraform.tfstate` and `terraform.tfstate.backup` (only present when not using remote backend)
- Removes `helm/values/values-overrides.yaml` and all `helm/values/langsmith-values-*.yaml` (generated by `make init-values`)
- Keeps `terraform.tfvars.example`, `helm/values/examples/`, and `.terraform/` cache

---

### `make clean-force` — Remove generated local files without confirmation prompt
Same as `make clean` but skips the interactive confirmation — useful in non-interactive shells or after `make destroy-force`.

---

### `make kubeconfig` — Fetch cluster credentials
**Script:** `helm/scripts/get-kubeconfig.sh`

- Reads `aks_cluster_name` and `resource_group_name` from `terraform output`
- Runs `az aks get-credentials --overwrite-existing`
- Merges the AKS context into `~/.kube/config` and sets it as the active context
- Prints `kubectl get nodes` so you can confirm connectivity immediately

---

### `make k8s-secrets` — Push secrets into the cluster
**Script:** `infra/scripts/create-k8s-secrets.sh`

Bridges Key Vault (Terraform's output) to Kubernetes (Helm's input). Safe to re-run — uses `--dry-run=client | kubectl apply` so it updates in place without recreating the secret.

- Resolves Key Vault name from `terraform output keyvault_name`
- Reads 8 secrets from Key Vault: `api_key_salt`, `jwt_secret`, `langsmith_license_key`, `initial_org_admin_password`, `deployments_encryption_key`, `agent_builder_encryption_key`, `insights_encryption_key`, `polly_encryption_key`
- Creates or updates `langsmith-config-secret` in the `langsmith` namespace
- Verifies all 8 keys are present and prints a pass/fail for each

> Helm reads this secret via `config.existingSecretName: langsmith-config-secret`. No secrets are stored in Helm values files.

---

### `make init-values` — Generate Helm values from Terraform outputs
**Script:** `helm/scripts/init-values.sh`

Translates Terraform outputs and `terraform.tfvars` flags into Helm values files. Re-running is safe — outputs are refreshed, existing hostname is preserved unless overridden.

- Reads from `terraform.tfvars`: `name_prefix`, `location`, `tls_certificate_source`, `ingress_controller`, `postgres_source`, `redis_source`, `sizing_profile`, `dns_label`, `langsmith_domain`, `enable_*` flags
- Reads from `terraform output`: storage account name, container name, Workload Identity client ID, namespace, admin email, cluster name
- Determines hostname in priority order: `langsmith_domain` → `dns_label` (→ `<label>.<region>.cloudapp.azure.com`) → AGIC: `terraform output agw_public_ip_fqdn` → existing value in file → interactive prompt
- Sets `ingressClassName` based on `ingress_controller`: `nginx`→`"nginx"`, `istio`/`istio-addon`→`"istio"`, `agic`→`"azure/application-gateway"`, `envoy-gateway`→Gateway API (`ingress.enabled: false`)
- Generates `helm/values/values-overrides.yaml` with: hostname, auth config, Blob WI config, Postgres/Redis blocks, Workload Identity annotations for 5 service accounts, ingress/TLS block
- Copies the selected sizing file from `examples/` into `helm/values/`
- Copies addon files based on `enable_*` flags: `agent-deploys` (with `url` and `tlsEnabled` injected automatically), `agent-builder`, `insights` (minimal in-cluster file or full external example), `polly`

---

### `make deploy` — Deploy LangSmith via Helm
**Script:** `helm/scripts/deploy.sh`

The main deploy command. Handles everything from pre-checks to post-deploy verification.

- Validates `values-overrides.yaml` exists (fails fast with `make init-values` hint if missing)
- Refreshes kubeconfig via `az aks get-credentials`
- Annotates the correct LoadBalancer service with `service.beta.kubernetes.io/azure-dns-label-name` (read from `dns_label` in tfvars) — dispatches to the right service/namespace based on `ingress_controller` (nginx, istio-addon, istio, envoy-gateway)
- Creates the `letsencrypt-prod` cert-manager `ClusterIssuer` if `tls_certificate_source = "letsencrypt"` (idempotent — skipped if it already exists)
- Runs `preflight-check.sh`: confirms kubectl, helm, az, terraform are on PATH; tests cluster connectivity; updates the `langchain` Helm repo
- Verifies `langsmith-config-secret` exists — auto-creates it from Key Vault if missing
- Reads `enable_*` feature flags from tfvars and validates addon dependencies (agent builder requires deployments)
- Builds the values chain and logs each file included: `values.yaml` → `values-overrides.yaml` → sizing overlay → addon overlays
- Guards against a stuck Helm release: auto-rolls back `pending-upgrade` state before proceeding
- Runs `helm upgrade --install langsmith langchain/langsmith --timeout 20m`
- Waits for core deployments to roll out (`frontend`, `backend`, `platform-backend`, `ingest-queue`, `queue`, and Deployments pods if enabled)
- Annotates the `langsmith-ksa` service account with the Workload Identity client ID (used by operator-spawned agent pods)
- Prints the access URL, login email, and the `az keyvault` command to retrieve the admin password

---

### `make deploy-all` — Full deploy in one shot (Helm path)
Runs `apply → kubeconfig → k8s-secrets → init-values → deploy` in sequence. Use after `terraform.tfvars` is fully configured and `make init` has been run.

---

### `make init-app` — Initialize the Terraform Helm module
**Script:** `app/scripts/pull-infra-outputs.sh` + `terraform init`

The entry point for the Terraform Helm path (Pass 2 via Terraform).

- Runs `app/scripts/pull-infra-outputs.sh`:
  - Reads 13 values from `terraform output` in `infra/`: cluster name, resource group, Key Vault name, storage account, storage container, Workload Identity client ID, namespace, TLS source, ingress controller, nginx DNS label, Front Door hostname, postgres source, redis source
  - Reads subscription ID from `az account show`
  - Writes all values into `app/infra.auto.tfvars.json` (gitignored) — consumed automatically by Terraform
- Runs `terraform init -input=false` in `app/`

> Run after `make apply`. Re-run after any infra changes to refresh `infra.auto.tfvars.json`.

---

### `make plan-app` — Plan the Terraform Helm module
Runs `init-app` then `terraform plan` in `app/`. Shows exactly what Kubernetes resources and Helm release values will be created or changed. Run before `make apply-app` to review the diff.

---

### `make apply-app` — Deploy LangSmith via Terraform (Helm path)
Runs `terraform apply` in `app/`. Creates or updates:

- **`kubernetes_secret_v1.langsmith_config`** — reads 4–8 secrets from Key Vault and writes `langsmith-config-secret` directly into Kubernetes. Equivalent to `make k8s-secrets` but managed in Terraform state.
- **`kubernetes_secret_v1.clickhouse`** — ClickHouse credentials secret (only when `enable_insights = true`)
- **`kubernetes_service_account_v1.langsmith_ksa`** — `langsmith-ksa` service account with `azure.workload.identity/client-id` annotation (only when `enable_agent_deploys = true`)
- **`helm_release.langsmith`** — Helm release using the same values chain as the shell path:
  ```
  values.yaml → overrides (yamlencode) → sizing file → addon files
  ```
- Runs 12 precondition checks before applying — fails fast with clear error messages if required variables are missing or dependencies are violated.

Feature flags in `app/terraform.tfvars` (equivalent to shell path flags):

```hcl
sizing              = "production"   # minimum | dev | production | production-large
enable_agent_deploys  = true         # Pass 3 — LangGraph Platform
enable_fleet          = true         # Pass 4 — Fleet, standalone (chart v0.15+; requires agent_deploys; also set enable_fleet in the infra pass)
enable_agent_builder  = false        # Pass 4 — Agent Builder, LEGACY (superseded by enable_fleet; mutually exclusive)
enable_insights       = true         # Pass 5 — Insights / ClickHouse
enable_polly          = true         # Pass 5 — Polly (requires agent_deploys)
```

> Prerequisites: `make init-app` must have run successfully; `app/terraform.tfvars` must have `admin_email` set.

---

### `make destroy-app` — Destroy the Terraform Helm module
Runs `terraform destroy` in `app/`. Removes the Helm release, K8s secrets, and the `langsmith-ksa` service account from Terraform state. Does **not** touch infra — run `make destroy` separately to remove AKS and Azure resources.

---

### `make deploy-all-tf` — Full deploy via Terraform (end-to-end)
Runs `apply → init-values → init-app → apply-app` in sequence. Combines Pass 1 infra and Pass 2 Terraform Helm into a single command. Use when you want the entire stack — from AKS to the running Helm release — managed by Terraform.

---

### `make uninstall` — Remove Helm releases
**Script:** `helm/scripts/uninstall.sh`

- Refreshes kubeconfig from Terraform outputs
- Deletes all `lgp` custom resources in the `langsmith` namespace (LangGraph Platform operator-managed deployments) before removing the operator that manages them
- Helm uninstalls `langsmith` with `--wait --timeout 5m`
- Prompts before deleting the `langsmith` namespace

> Run before `make destroy`. Follow with `make clean` to remove local secrets and generated files.

---

### `make status` / `make status-quick` — Health check
**Script:** `infra/scripts/status.sh`

Runs 10 checks and prints a pass/warn/fail for each:

1. **Terraform outputs** — reads cluster name, resource group, Key Vault name
2. **Cluster connectivity** — `kubectl cluster-info`
3. **Nodes** — Ready count vs total count
4. **Bootstrap components** — pod counts for cert-manager, KEDA, ingress controller (dispatches by `ingress_controller`: nginx/istio-addon/istio/envoy-gateway/agic)
5. **LangSmith pods** — Running/Completed counts; flags anything not in those states
6. **Helm release** — status (deployed / failed / pending-upgrade) and chart version
7. **Ingress + TLS** — ingress hosts and certificate Ready status
8. **Key Vault secrets** — total secret count in the vault _(skipped with `--quick`)_
9. **`langsmith-config-secret`** — key count; warns if fewer than 8 keys _(skipped with `--quick`)_
10. **Terraform Helm App path** — checks `app/infra.auto.tfvars.json` and `app/` Terraform state; shows chart version if applied

`make status-quick` skips sections 8 and 9 (no Key Vault API calls) — useful during rollouts when you just want pod counts.

---

### Addon feature flags

Addon passes (3–5) are controlled by flags in `infra/terraform.tfvars`:

```hcl
sizing_profile       = "production"   # minimum | dev | production | production-large
enable_deployments   = true           # Pass 3 — LangSmith Deployments (listener + operator + host-backend)
enable_fleet         = true           # Pass 4 — Fleet, standalone (chart v0.15+; requires enable_deployments)
enable_agent_builder = false          # Pass 4 — Agent Builder UI, LEGACY (superseded by enable_fleet; mutually exclusive)
enable_insights      = true           # Pass 5 — Insights / Clio (ClickHouse-backed analytics)
enable_polly         = true           # Pass 5 — Polly AI evaluation (requires enable_deployments)
```

**Pass 3** requires a node pool scale-up before deploying — operator-spawned pods need headroom. Set `default_node_pool_min_count = 5` and run `make apply` first, then `make init-values && make deploy`.

**Passes 4–5** only need `make init-values && make deploy` — no `terraform apply` required.

---

## Helm Values Files

Helm values are layered — later files override earlier ones. `make deploy` applies them in this order:

```
values.yaml  →  values-overrides.yaml  →  sizing file  →  addon files
```

All files in `helm/values/` are **gitignored** (generated or contain live secrets). The source templates live in `helm/values/examples/` and are copied by `make init-values`.

---

### `values.yaml` — Azure base config
**Location:** `helm/values/values.yaml` (tracked in git)

The Azure-specific base that applies on every deploy. Sets NGINX as the ingress class, configures Blob Storage with Workload Identity (no static credentials), and disables Istio gateway. You should not need to edit this file — environment-specific overrides go in `values-overrides.yaml`.

---

### `values-overrides.yaml` — Your deployment
**Location:** `helm/values/values-overrides.yaml` (gitignored, generated by `make init-values`)

The live file for your specific deployment. Generated fresh from Terraform outputs each time you run `make init-values`. Contains:

- `config.hostname` — your FQDN (from `dns_label` or `langsmith_domain`)
- `config.initialOrgAdminEmail` — the first org admin account
- `config.existingSecretName: langsmith-config-secret` — tells Helm where to find all secrets
- `config.blobStorage` — Azure storage account name + container + Workload Identity client ID
- Workload Identity annotations for 5 service accounts (backend, platform-backend, queue, ingest-queue, host-backend)
- Ingress + TLS block (cert-manager annotation, TLS secret name) based on `tls_certificate_source`
- Postgres and Redis external secret references (if using managed services)

> Edit freely after generation — re-running `make init-values` will overwrite it.

---

### Sizing files — Resource profiles

See **[helm/values/examples/SIZING.md](helm/values/examples/SIZING.md)** for full resource tables — CPU, memory, replicas, and HPA ranges for every component across all profiles.

`make init-values` copies one of these to `helm/values/` based on `sizing_profile` in `terraform.tfvars`.

| File | Profile | When to use |
|------|---------|-------------|
| `langsmith-values-sizing-minimum.yaml` | `minimum` | Absolute floor — fits everything on a single small node (4 vCPU / 16 Gi). Rock-bottom CPU/memory requests from real `kubectl top` measurements on idle. **Expect OOM kills under any real traffic.** Use for cost parking, weekend standby, or single-user demos. |
| `langsmith-values-sizing-dev.yaml` | `dev` | Light non-production profile for local dev, CI pipelines, integration tests, and short-lived POCs. Single replica per component, no autoscaling. Will show instability under real workloads — that is expected. |
| `langsmith-values-sizing-production.yaml` | `production` | **Recommended for production.** Multi-replica deployments with HPA on all stateless components. Sensible CPU/memory starting points — tune with `kubectl top pods -n langsmith` after go-live. |
| `langsmith-values-sizing-production-large.yaml` | `production-large` | High-volume starting point based on the LangSmith scale guide (~50 concurrent users, ~1000 traces/sec). Elevated HPA minimums (e.g. 10 backend replicas). Start with `production` and move here when monitoring shows sustained pressure. |

---

### Addon files — Feature overlays

These are copied to `helm/values/` by `make init-values` when the corresponding `enable_*` flag is set.

**`langsmith-values-agent-deploys.yaml`** — Pass 3 (`enable_deployments = true`)

Enables the LangGraph Platform: the Deployments nav item in the UI, the `listener` pod (watches for new deployment requests), and the `operator` pod (spawns and manages agent pods). Also includes the operator's deployment template — the spec used when it creates agent pods. `make init-values` automatically injects `config.deployment.url` (your FQDN with protocol) and `config.deployment.tlsEnabled` so the operator builds correct endpoint URLs.

> Without the correct `url` and `tlsEnabled`, agent deployments will get stuck in `DEPLOYING` state indefinitely.

**`langsmith-values-fleet.yaml`** — Pass 4 (`enable_fleet = true`)

Enables standalone Fleet, the re-architected successor to Agent Builder (chart v0.15+). Deploys as its own service via the top-level `fleet.*` values with a dedicated `langsmith_fleet` Postgres database (created by the infra pass, wired via the `langsmith-fleet-postgres` secret) and the chart's in-cluster bundled Redis. Also enables `fleetToolServer` (tool registry) and `fleetTriggerServer` (execution triggers). The `fleetToolServer` gets a relaxed startup probe — its 0.15.x image CPU-pegs on startup and can't bind its port within the chart's default 60s probe window, so it CrashLoopBackOffs without a longer window. (No resources override: the chart's default 2 CPU / 4Gi is adequate, and the namespace LimitRange sets only defaults — not a `max` — so it never reduces a chart-sized container.) The encryption key is reused from `langsmith-config-secret` (`agent_builder_encryption_key`); it is never set inline.

> Requires `enable_deployments = true`. Mutually exclusive with `enable_agent_builder`.

**`langsmith-values-agent-builder.yaml`** — Pass 4 (`enable_agent_builder = true`) — **legacy, superseded by `enable_fleet`**

Enables the visual agent builder UI and its two supporting services: `fleetToolServer` (exposes the tool registry) and `fleetTriggerServer` (handles agent execution triggers). Also enables `backend.agentBootstrap` — a post-install job that registers Agent Builder as an LGP deployment and creates the required ConfigMap. Without this job, the Agent Builder nav item does not appear in the UI. Sets conservative agent worker pod resources (1 CPU / 1 Gi) instead of the chart's default 4 CPU / 8 Gi.

> Requires `enable_deployments = true`. Prefer `enable_fleet` for new deployments.

**`langsmith-values-insights.yaml`** — Pass 5 (`enable_insights = true`)

Enables ClickHouse-backed analytics in the Insights tab. The file generated depends on `clickhouse_source` in `terraform.tfvars`:

- `in-cluster` → minimal file with just `config.insights.enabled: true`. The Helm chart manages ClickHouse internally. No external connection needed.
- `external` → full file with `clickhouse.external.enabled: true` and a `langsmith-clickhouse` secret reference. You must create the secret and fill in the ClickHouse host/credentials before deploying.

**`langsmith-values-polly.yaml`** — Pass 5 (`enable_polly = true`)

Enables Polly, the AI-powered evaluation and monitoring agent. Polly runs as an LGP deployment (operator-managed pod). Sets resource limits for Polly's agent worker (2 CPU / 4 Gi request, 4 CPU / 8 Gi limit, scales 1–5 replicas).

> Requires `enable_deployments = true`.

---

## Repository Layout

```
azure/
├── Makefile                    # Task runner — start here
├── infra/                      # Pass 1: Terraform — Azure infrastructure
│   ├── main.tf                 # Module wiring
│   ├── variables.tf            # All input variables
│   ├── outputs.tf              # Terraform outputs (storage, identity, connection URLs)
│   ├── terraform.tfvars.example
│   ├── terraform.tfvars.minimum    # Minimal variable set (light deploy)
│   ├── terraform.tfvars.dev        # Dev/CI variable set
│   ├── terraform.tfvars.production # Production variable set
│   ├── secrets.auto.tfvars         # Generated by setup-env.sh — gitignored, never commit
│   └── scripts/
│       ├── _common.sh              # Shared helpers: _parse_tfvar, _tfvar_is_true, color output
│       ├── setup-env.sh            # Bootstrap secrets → secrets.auto.tfvars
│       ├── preflight.sh            # Pre-flight checks (az CLI, auth, providers, RBAC)
│       ├── status.sh               # 10-section health check (supports --quick)
│       ├── create-k8s-secrets.sh   # Key Vault → langsmith-config-secret
│       └── clean.sh                # Remove all generated/sensitive local files after teardown
├── app/                        # Pass 2 (Terraform path): Helm release managed by Terraform
│   ├── main.tf                 # azurerm + kubernetes + helm providers; KV secrets; helm_release
│   ├── variables.tf            # Infra inputs (from pull-infra-outputs.sh) + app config
│   ├── locals.tf               # Hostname resolution, WI annotations, Helm overrides values
│   ├── outputs.tf              # langsmith_url, release_name, release_status, chart_version
│   ├── versions.tf             # azurerm ~> 3.0, helm ~> 2.16, kubernetes ~> 2.37
│   ├── backend.tf.example      # Azure Blob backend template (copy to backend.tf)
│   ├── terraform.tfvars.example
│   ├── infra.auto.tfvars.json  # Generated by pull-infra-outputs.sh — gitignored
│   └── scripts/
│       └── pull-infra-outputs.sh   # Reads infra TF outputs → writes infra.auto.tfvars.json
├── helm/                       # Pass 2 (Helm path): shell-script-based Helm deploy
│   ├── scripts/
│   │   ├── deploy.sh           # Helm values chain deploy (base + overrides + sizing + addons)
│   │   ├── init-values.sh      # TF outputs → values-overrides.yaml; copies sizing + addon files
│   │   ├── get-kubeconfig.sh   # az aks get-credentials wrapper
│   │   ├── preflight-check.sh  # Tools check + cluster connectivity + Helm repo
│   │   └── uninstall.sh        # Clean Helm uninstall (Azure LB warning included)
│   └── values/
│       ├── values.yaml                              # Azure base (NGINX, Blob WI, external secrets)
│       ├── values-overrides.yaml                    # Live file — gitignored, generated by init-values.sh
│       └── examples/
│           ├── SIZING.md                                 # Sizing guide — resource tables for all profiles
│           ├── langsmith-values-sizing-minimum.yaml      # Absolute minimum resources
│           ├── langsmith-values-sizing-dev.yaml          # Dev / CI sizing
│           ├── langsmith-values-sizing-production.yaml   # Production (multi-replica + HPA)
│           ├── langsmith-values-sizing-production-large.yaml  # High-volume (~1000 traces/sec)
│           ├── langsmith-values-agent-deploys.yaml            # Pass 3 — LangGraph Platform
│           ├── langsmith-values-agent-builder.yaml            # Pass 4 — Agent Builder (legacy)
│           ├── langsmith-values-fleet.yaml                    # Pass 4 — Fleet (standalone, chart v0.15+)
│           ├── langsmith-values-insights.yaml                 # Pass 5 — Insights / Clio
│           ├── langsmith-values-polly.yaml                    # Pass 5 — Polly
│           ├── langsmith-values-ingress-agic.yaml             # Ingress: AGIC (azure/application-gateway)
│           ├── langsmith-values-ingress-istio.yaml            # Ingress: Istio / istio-addon
│           ├── langsmith-values-ingress-envoy-gateway.yaml    # Ingress: Envoy Gateway (Gateway API)
│           └── letsencrypt-issuer-dns01.yaml                  # cert-manager ClusterIssuer for DNS-01 TLS
```

---

## Terraform Modules

| Module | Required | Description |
|--------|----------|-------------|
| `networking` | yes | VNet, subnets (main, postgres, redis, bastion, agic). AGIC subnet (`10.0.96.0/24`) is created automatically when `ingress_controller = "agic"`. Multi-AZ zone pinning supported. Can also create subnets inside a VNet you already own — see [Bring your own VNet](#bring-your-own-vnet). |
| `k8s-cluster` | yes | AKS cluster, node pools, OIDC issuer, managed identity, federated credentials (Workload Identity centralized here). Installs ingress controller via Helm: nginx / istio / istio-addon / agic (App Gateway v2 + AGIC chart) / envoy-gateway. |
| `k8s-bootstrap` | yes | Kubernetes namespace, ServiceAccount, cert-manager, KEDA, postgres/redis K8s secrets. |
| `storage` | yes | Azure Blob storage account + container. |
| `keyvault` | yes | Azure Key Vault (RBAC mode, soft-delete) + all application secrets. |
| `postgres` | optional | Azure DB for PostgreSQL Flexible Server. Enabled when `postgres_source = "external"`. Multi-AZ standby supported. |
| `redis` | optional | Azure Cache for Redis Premium. Enabled when `redis_source = "external"`. |
| `dns` | optional | Azure DNS zone + A record. Required for DNS-01 cert issuance (`tls_certificate_source = "dns01"`). |
| `waf` | optional | Azure WAF policy (OWASP 3.2 + bot protection). Use `agw_sku_tier = "WAF_v2"` with AGIC for integrated WAF — no separate module needed. |
| `diagnostics` | optional | Log Analytics workspace + diagnostic settings for AKS, Key Vault, and Blob. |
| `bastion` | optional | Azure Bastion (Standard tier) for private SSH/RDP to cluster nodes. |

> **Workload Identity** is centralized in `k8s-cluster`. Federated credentials for blob-accessing pods (backend, platform-backend, queue, ingest-queue, host-backend, listener, agent-builder-tool-server, agent-builder-trigger-server) are registered there. Adding a new pod that needs Blob access requires updating `service_accounts_for_workload_identity` in `k8s-cluster` and running `terraform apply -target=module.aks`.
>
> **AGIC Workload Identity** uses a separate managed identity (`<cluster>-agic-identity`) with Contributor on the App Gateway and Reader on the resource group. The federated credential binds to `system:serviceaccount:ingress-basic:ingress-azure`.

---

## Bring your own VNet

By default Terraform creates the VNet and every subnet. To deploy into a VNet
your network team already manages, set `create_vnet = false` and name it:

```hcl
create_vnet = false
vnet_id     = "/subscriptions/<sub>/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/corp-vnet"
```

Each subnet is then independent. Supply an ID to reuse a subnet you already
have, or leave it out and Terraform creates that subnet inside your VNet from
the matching address prefix:

```hcl
# Reuse an existing Postgres subnet, let Terraform carve the other two.
postgres_subnet_id             = "/subscriptions/.../virtualNetworks/corp-vnet/subnets/pg"
aks_subnet_address_prefix      = ["10.42.0.0/19"]
redis_subnet_address_prefix    = ["10.42.32.0/20"]
```

Subnets Terraform creates land in the existing VNet's resource group, not the
LangSmith one, and get the settings each service needs:

| Subnet | What Terraform applies |
|--------|------------------------|
| AKS | `Microsoft.Storage` and `Microsoft.KeyVault` service endpoints, so the storage and Key Vault default-deny firewalls can allowlist the subnet |
| Postgres | Delegation to `Microsoft.DBforPostgreSQL/flexibleServers` — Flexible Server injects its NICs here, and no other resource may share the subnet |
| Redis | No delegation. Azure Managed Redis is reached through a private endpoint placed in this subnet; a delegated subnet would reject it |

The default prefixes above are sized against the `10.0.0.0/17` VNet Terraform
builds, so they are a starting point rather than a default that fits your
network. Plan reads your VNet and rejects a prefix that falls outside its
address space, and rejects an AKS prefix too small for the node pools whether
the subnet is one you supplied or one Terraform carves. What it cannot check is
whether a prefix collides with a subnet that already exists in the VNet, because
Azure's VNet read returns subnet names and not their ranges — so pick ranges you
know are free.

`aks_service_cidr` is required on this path when Terraform creates the cluster.
Kubernetes assigns ClusterIPs from it, and AKS requires a range that nothing on
or connected to your VNet uses. The `10.0.64.0/20` default only avoids the VNet
Terraform builds, and an overlap with your own address space can be accepted when
the cluster is created and break later, so plan makes you name one and rejects one
that lands inside your VNet. Peered and on-premises ranges are still yours to keep
clear of, since plan only sees the VNet itself. `aks_dns_service_ip` follows from
`aks_service_cidr` automatically as the eleventh address unless you set one.

Attaching to an existing cluster (`create_cluster = false`) ignores both. Azure
fixes the ClusterIP range when the cluster is created and it cannot be changed
afterwards, so plan neither asks for a value nor checks one.

### What a subnet you supply must already have

| Subnet | Requirement |
|--------|-------------|
| AKS | Both the `Microsoft.Storage` and `Microsoft.KeyVault` service endpoints. The blob storage firewall is hardcoded to default-deny and allowlists this subnet by ID, and Azure rejects a subnet rule when the matching endpoint is missing. Required whatever `keyvault_default_action` is set to. Must also be large enough for the configured node pools, since Azure CNI draws both node and pod IPs from it: `(max_count + 1) × (max_pods + 1)` addresses per pool, which is 764 at the defaults and needs a `/22` or larger |
| Postgres | Delegation to `Microsoft.DBforPostgreSQL/flexibleServers`, with the `Microsoft.Network/virtualNetworks/subnets/join/action` action, and no other resources in the subnet. Azure's floor for a delegated subnet is `/28` |
| Redis | No delegation, since it holds a private endpoint and Azure allows no other resource type in a delegated subnet |
| AGIC | The subnet to itself. Application Gateway v2 shares with nothing, and Azure recommends a `/24`. Only needed when `ingress_controller = "agic"` |
| Bastion | The name `AzureBastionSubnet`, exactly, and `/26` or larger. Azure refuses any other name. Only needed when `create_bastion = true` |

Every subnet you supply must be a different subnet. Sharing one fails during
apply, because the Postgres subnet is delegated and Azure permits nothing else
inside a delegated subnet, and because Application Gateway and Bastion each
require a subnet of their own.

### What Terraform checks before applying

These fail at plan time with an actionable message rather than partway through
an apply:

- `vnet_id` is present and is a well-formed VNet resource ID
- every supplied subnet is a subnet of `vnet_id` — one in a different VNet would
  be unreachable, since the private DNS zones are linked to `vnet_id`
- every supplied subnet ID names a different subnet
- a supplied Postgres subnet already carries the `flexibleServers` delegation
- a supplied AKS subnet carries both service endpoints
- a supplied bastion subnet is named `AzureBastionSubnet`, which Azure requires
  and a well-formed resource ID does not guarantee
- `agic_subnet_id` is set when AGIC is on, and `bastion_subnet_id` when the
  bastion is, since neither is carved inside a VNet you own
- the AKS subnet has enough addresses for the configured node pools, whether you
  supplied it or Terraform creates it. Undersizing is the one mistake that
  survives apply: the cluster starts, and the autoscaler later stalls short of
  `max_count` once the subnet runs dry
- every prefix Terraform is about to carve sits inside your VNet's address
  space. The defaults describe the VNet Terraform builds, so this is usually the
  first thing to change on a network of your own
- `aks_service_cidr` is set, and does not overlap your VNet's address space, when
  Terraform creates the cluster. Attaching to an existing one skips both checks,
  since its ClusterIP range is already fixed and this value cannot change it
- subnet IDs are not set while `create_vnet = true`, where they would be ignored

Whoever runs Terraform needs two kinds of access to the VNet, which normally
lives in the network team's resource group rather than the LangSmith one:

- **read** on `vnet_id` and on whichever subnets you supply, at plan time, for
  the checks above
- **`Microsoft.Network/virtualNetworks/subnets/write`** on `vnet_id` for every
  subnet you leave Terraform to create. This is the larger ask of a network
  team, and it fails at apply rather than at plan, so settle it first

### AGIC and the bastion are supply-only here

`create_bastion = true` and `ingress_controller = "agic"` each need a subnet to
themselves. Terraform carves those two only out of a VNet it owns, so on this
path you name subnets that already exist:

```hcl
agic_subnet_id    = "/subscriptions/.../virtualNetworks/corp-vnet/subnets/appgw"
bastion_subnet_id = "/subscriptions/.../virtualNetworks/corp-vnet/subnets/AzureBastionSubnet"
```

Unlike the other three there is no carve fallback, so plan rejects either
feature when `create_vnet = false` and its subnet ID is empty. Application
Gateway v2 wants the subnet to itself and Azure recommends a `/24`. Azure Bastion
requires the subnet be named exactly `AzureBastionSubnet` and be `/26` or larger;
plan checks the name, and Azure enforces the size at apply.

---

## Multi-AZ Support

```hcl
# Spread AKS nodes across zones 1, 2, 3
availability_zones = ["1", "2", "3"]

# PostgreSQL HA standby in a different zone
postgres_high_availability_mode = "ZoneRedundant"
```

Zone-redundant PostgreSQL requires `GeneralPurpose` or `MemoryOptimized` SKU.

---

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md).

## Service Reference

See [SERVICES.md](SERVICES.md) — what each pod does, what it depends on, and which pass enables it.

## Light Deploy (Demo / POC)

See [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md) — full guide for all-in-cluster deployment (no external Postgres/Redis), using Front Door for TLS.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — issues, gotchas, and fixes. Read before deploying.
