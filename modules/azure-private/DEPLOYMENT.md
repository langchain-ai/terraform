# Deploying LangSmith with `modules/azure-private`

A practical runbook for the **private / hub-and-spoke** LangSmith landing zone. Read this
alongside [README.md](README.md) (which is the reference for every input variable and the
three DNS / identity modes). This document answers three questions:

1. **What must the customer have in place first?** (hub-and-spoke? firewall? — yes; details below)
2. **Is there an example tfvars file?** (yes — [`infra/terraform.tfvars.example`](infra/terraform.tfvars.example))
3. **What are the actual steps to deploy LangSmith?**

> **Two ways in — same phases, different starting point:**
> - **Path A — Test-drive from scratch.** No enterprise VNet handy? Stand up a throwaway
>   hub-spoke landing zone + Azure Firewall with the [`test/hub-spoke/`](test/hub-spoke/) scaffold,
>   paste its `azure_private_tfvars` output into `infra/terraform.tfvars`, then follow the phases
>   below from [Phase 1](#phase-1--azure-infrastructure-run-from-anywhere).
> - **Path B — Bring your own VNet (production).** You already own the RG + VNet + firewall. Start
>   at [Customer prerequisites](#customer-prerequisites-provision-before-terraform-apply), then the
>   phases.
>
> Prefer a picture? [architecture.html](architecture.html) is a one-page visual of what's built,
> what's a prerequisite, and the deploy order.

> **Two Terraform roots — two apply runs.** `modules/azure-private` is split into two roots:
> - **`infra/`** — azurerm-only. Creates the AKS cluster, Postgres, Redis, Blob, Key Vault,
>   bastion, and diagnostics. Has **no** Kubernetes or Helm providers. Run it from anywhere
>   (your laptop, a CI runner) — it is **never blocked by the private API server**.
> - **`bootstrap/`** — in-cluster. Installs KEDA, NGINX, the `langsmith` namespace,
>   and K8s secrets (read from Key Vault). Must run **from the jumpbox** (inside the VNet) after
>   the cluster is up.
>
> You do **not** need to be in the VNet for the `infra/` apply. You **do** need to be in the
> VNet (on the jumpbox) for the `bootstrap/` apply.

> **This module does not use the `make` workflow** that `modules/azure` uses. There is no
> `Makefile`, no bundled Helm chart, and no `app/` Terraform here — only the `infra/` and
> `bootstrap/` roots and the `infra/scripts/` helpers. You run Terraform directly. See
> [No make pattern](#no-make-pattern-vs-modulesazure).

---

## What this module does / doesn't do

| | |
|---|---|
| ✅ **Does** | Provisions the hardened Azure infra (AKS private cluster with CNI Overlay+Cilium and UDR egress, PostgreSQL Flexible Server + Redis via **Private Endpoint**, Blob, Key Vault, a jumpbox VM, Log Analytics) **into your existing RG + VNet** (`infra/`), and bootstraps the cluster in a **separate apply from the jumpbox** (namespace, RBAC, network policies, the Postgres/Redis connection K8s secrets, KEDA, internal NGINX ingress) (`bootstrap/`). The app-config secret (`langsmith-config-secret`) and the TLS secret (`langsmith-tls`) are created by scripts in [Phase 3.5](#phase-35--create-the-app-config-secret). |
| ❌ **Does not** | Create the resource group or VNet (you bring them). Create the firewall/route table (you bring them). Install the **LangSmith application** itself — that is a separate Helm step ([Phase 4](#phase-4--install-the-langsmith-application-helm)). Provide a `Makefile` or app-deploy automation. |

After both `infra/` and `bootstrap/` apply you have a running, hardened cluster with ingress and
supporting services — but **not** LangSmith. LangSmith is installed afterward via its Helm chart.

---

## Is this the hub-and-spoke / firewall path? — Yes

This module **is the spoke**. It is built for an enterprise landing zone and assumes the
surrounding network already exists. Concretely, three hard assumptions are baked in (they are
not toggles):

- **Egress is `userDefinedRouting`.** There is no public load-balancer egress. The AKS subnet
  **must** have a route table with `0.0.0.0/0` → your **firewall / NVA** private IP, and that
  firewall **must allow the required AKS egress** before you apply. If egress doesn't work, the
  AKS nodes cannot reach the control plane or pull images and **cluster creation fails**. A
  firewall/NVA is therefore effectively **required** (Azure Firewall in a hub is the canonical
  setup; any NVA with the right rules works). See
  [Control egress traffic for AKS](https://learn.microsoft.com/azure/aks/limit-egress-traffic).
- **The API server is private.** No public endpoint. The `bootstrap/` apply (Helm/kubectl)
  **must run from inside the VNet** (on the jumpbox) where the private API IP is reachable and
  the private DNS zone resolves. The `infra/` apply has **no** Kubernetes/Helm providers and is
  **not** blocked by the private API — run it from anywhere.
- **Everything is BYO + private.** Existing RG (region inherited from it), existing VNet +
  subnets, backing services reachable only via Private Endpoint.

You do **not** strictly need a textbook hub-and-spoke, but you **do** need: a VNet whose AKS
subnet routes egress through a firewall/NVA, private DNS resolution for the API server, and a
jumpbox (or peered runner) inside that VNet for the `bootstrap/` apply. That is the
hub-and-spoke pattern in practice.

---

## Customer prerequisites (provision BEFORE `terraform apply`)

### Tools (on the apply host)
`az` (Azure CLI ≥ 2.50), `terraform` ≥ 1.5 (the repo is validated on 1.x; the offline test
suite needs ≥ 1.7), `kubectl`, and `helm` ≥ 3.12 (for Phase 4).

The `infra/` apply only needs `az` + `terraform`. `kubectl` and `helm` are needed only on the
jumpbox for the `bootstrap/` apply and the Phase 4 Helm install.

### Azure RBAC for the Terraform principal
- **Contributor** + **User Access Administrator** on the subscription/RG (or **Owner**).
  Contributor alone is insufficient — the module creates role assignments (Key Vault, Blob,
  the control-plane identity's Network Contributor grant).
- **Network Contributor on the existing VNet** (or a custom role with
  `Microsoft.Network/virtualNetworks/subnets/join/action`) so AKS / the private endpoints can
  join your subnets.

### Network (you create these; the module consumes them)
- [ ] **Resource group** — existing; you have Contributor+. Deployment **region is inherited
  from it** (there is no `location` variable).
- [ ] **VNet** — existing, with non-overlapping CIDRs vs `aks_service_cidr` and `aks_pod_cidr`.
- [ ] **AKS subnet** with **both**:
  - a **route table** associated, `0.0.0.0/0` → firewall/NVA private IP (UDR), and
  - the **`Microsoft.Storage` + `Microsoft.KeyVault` service endpoints** enabled (Blob and Key
    Vault default-deny firewalls allowlist the AKS subnet via these — without them, pods can't
    reach Blob/Key Vault).
- [ ] **Postgres subnet** — a regular subnet with a spare IP for the **Private Endpoint**.
  **Not** delegated (delegation is VNet injection, which this module does not use). Required
  when `postgres_source = "external"` (the default).
- [ ] **Redis subnet** — a regular subnet for the Redis **Private Endpoint**. Required when
  `redis_source = "external"` (the default).
- [ ] **Jumpbox subnet** — for the apply-host VM the module provisions. **Use a normal subnet
  name** (e.g. `jumpbox`); do **not** use `AzureBastionSubnet` (Azure reserves that name for
  the Azure Bastion PaaS service and rejects a plain VM there).
- [ ] **Firewall / NVA** reachable from the AKS subnet route table, configured to **allow the
  required AKS egress** (control-plane FQDNs/ports).

### Private DNS
- [ ] An **apply host that can resolve the AKS API server's private DNS zone**
  (`privatelink.<region>.azmk8s.io`). This is only required for the **`bootstrap/` apply**
  (which must run from the jumpbox). The `infra/` apply has no Kubernetes provider and is not
  affected. With the default `aks_private_dns_zone_id = ""` (System zone), AKS auto-links the
  zone to your VNet, so a host in that VNet resolves it. For `"None"` or a custom zone, you
  own resolution (see README "API-server private DNS"). If your VNet uses **custom DNS
  servers**, add a conditional forwarder for `privatelink.*` → `168.63.129.16`.
- [ ] **Centrally-managed private DNS caveat:** this module **creates** the
  `privatelink.postgres.database.azure.com` and `privatelink.redis.azure.net` zones and links
  them to your VNet. If a platform team already manages those zones and links them to the VNet,
  that conflicts (a VNet can't link two same-named zones). There is no BYO-zone toggle for
  Postgres/Redis yet.

### State backend
`infra/` and `bootstrap/` ship **no** active backend (local state by default). For any real
or team deployment, configure an Azure Storage remote backend for each root: copy
[`infra/backend.tf.example`](infra/backend.tf.example) to `infra/backend.tf` and fill in your
storage account/container. `bootstrap/` has no example backend file — if you want its state
remote too, add a `bootstrap/backend.tf` by hand (the same block, with a different state key).

The two roots do **not** need a *shared* backend: `bootstrap/` does not read `infra/`'s state —
it discovers everything via Azure data sources + Key Vault and only needs its three variables
(`subscription_id`, `resource_group_name`, `identifier`).

---

## The example tfvars

[`infra/terraform.tfvars.example`](infra/terraform.tfvars.example) is the single worked
configuration for the `infra/` root. Copy it and fill in your IDs:

```bash
cd modules/azure-private/infra
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — subscription_id, resource_group_name, vnet_id, the four subnet IDs,
# CIDRs, the DNS/identity knobs, and bastion_admin_ssh_public_key
```

The `bootstrap/` root needs only three variables (`subscription_id`, `resource_group_name`,
`identifier`) — all others default correctly when the same `identifier` was used for `infra/`.

Only `subscription_id` has no default, but the BYO IDs and secrets are **functionally
required** — empty values fail at apply. The few real knobs (everything else is hardcoded):

| Variable | Notes |
|---|---|
| `subscription_id`, `resource_group_name` | Target subscription + existing RG |
| `vnet_id`, `aks_subnet_id`, `postgres_subnet_id`, `redis_subnet_id`, `bastion_subnet_id` | Your existing network |
| `aks_service_cidr`, `aks_dns_service_ip`, `aks_pod_cidr` | Non-overlapping with the VNet/peers |
| `aks_private_dns_zone_id`, `aks_private_cluster_public_fqdn_enabled` | API-server DNS mode (README) |
| `aks_create_cluster_identity` / `aks_cluster_identity_id` | Control-plane identity (default: module-created user-assigned) |
| `postgres_source` / `redis_source` | `external` (managed, Private Endpoint) or `in-cluster` (dev) |
| Secrets | `postgres_admin_password`, `langsmith_license_key`, `langsmith_api_key_salt`, `langsmith_jwt_secret`, `langsmith_admin_password` — supply via `TF_VAR_*` env vars or the `scripts/setup-env.sh` flow; never commit them (`*.tfvars` is gitignored) |

---

## Deployment steps

### Phase 0 — Authenticate & pre-flight
```bash
az login
az account set --subscription "<SUB_ID>"
cd modules/azure-private/infra
bash scripts/preflight.sh     # checks login, resource providers, RBAC, terraform.tfvars
```

### Phase 1 — Azure infrastructure (run from anywhere)

The `infra/` root has **no** Kubernetes or Helm providers. It creates only Azure resources
(AKS cluster, Postgres, Redis, Blob, Key Vault, bastion, diagnostics) and is **never blocked
by the private API server**. Run it from your laptop, a CI runner, or any host with az + terraform.

```bash
cd modules/azure-private/infra
# Secrets: either export TF_VAR_* for each secret, or use the bootstrap helper which
# prompts on first run and reads them back from Key Vault on subsequent runs:
bash scripts/setup-env.sh     # writes secrets.auto.tfvars (gitignored)

terraform init                # add backend.tf first for remote state (recommended)
terraform plan                # review: NO resource group / NO module.vnet created; AKS shows
                              # overlay/cilium, outbound_type=userDefinedRouting, private cluster
terraform apply
```

**Result (~15–20 min):** AKS cluster up; Postgres/Redis private endpoints; Blob + Key Vault
(with postgres/redis connection URLs stored as secrets); bastion jumpbox VM. The cluster has
no workloads — KEDA, NGINX, and K8s secrets are installed in Phase 3.

### Phase 2 — Cluster access + verify
```bash
# Run from any host that can reach your Azure subscription (doesn't need VNet connectivity).
az aks get-credentials --resource-group "<RG>" \
  --name "$(terraform -chdir=modules/azure-private/infra output -raw aks_cluster_name)" \
  --overwrite-existing
# Verify from inside the VNet (jumpbox or peered runner):
kubectl get nodes                         # Ready
terraform -chdir=modules/azure-private/infra output aks_private_fqdn   # the private API endpoint
```

> **kubectl access:** the API server is private — `kubectl` commands must run from the jumpbox
> (or a peered runner that resolves the private DNS zone). Getting credentials (`az aks
> get-credentials`) can run from anywhere; the actual API calls need VNet connectivity.

### Phase 3 — In-cluster bootstrap (from the jumpbox)

The `bootstrap/` root installs KEDA, the internal NGINX ingress controller,
the `langsmith` namespace, and the **Postgres/Redis connection** K8s secrets (read from Key
Vault). It **must** run from inside the VNet where the private API server is reachable. The
app-config secret (license key, salts, encryption keys) is **not** created here — that is
[Phase 3.5](#phase-35--create-the-app-config-secret).

```bash
# SSH to the jumpbox first:
# ssh azureuser@<jumpbox-public-ip>

# On the jumpbox — clone the repo, then:
cd modules/azure-private/bootstrap

# Supply the three required variables (or set TF_VAR_*):
terraform init
terraform plan -var="subscription_id=<SUB>" \
               -var="resource_group_name=<RG>" \
               -var="identifier=<IDENTIFIER>"
terraform apply -var="subscription_id=<SUB>" \
                -var="resource_group_name=<RG>" \
                -var="identifier=<IDENTIFIER>"
```

**Result:** namespace `langsmith` with the Postgres/Redis connection K8s secrets;
KEDA, and an **internal** NGINX ingress (private IP only). LangSmith itself is **not** installed yet.

Verify:
```bash
kubectl -n langsmith get secret            # langsmith-postgres-secret / langsmith-redis-secret present
kubectl get pods -A | grep -E 'keda|ingress-nginx'   # Running
```

### Phase 3.5 — Create the app-config secret

The LangSmith chart reads the license key, API-key salt, JWT secret, initial admin password,
and any feature encryption keys from a single Kubernetes secret referenced by
`config.existingSecretName`. That secret (`langsmith-config-secret`) is **not** created by the
`bootstrap/` apply — create it from Key Vault with the vendored helper, which uses the exact
key names the chart expects:

```bash
# From the jumpbox, with kubectl pointed at the cluster:
bash modules/azure-private/infra/scripts/create-k8s-secrets.sh
kubectl -n langsmith get secret langsmith-config-secret   # confirm it exists
```

This reads `langsmith-license-key`, `langsmith-api-key-salt`, `langsmith-jwt-secret`,
`langsmith-admin-password`, and the four feature encryption keys from Key Vault and writes them
into `langsmith-config-secret`. Skipping this step makes the Helm install (which sets
`config.existingSecretName: langsmith-config-secret`) fail with a missing-secret error.

**TLS secret (`langsmith-tls`).** The internal NGINX ingress terminates TLS using a Kubernetes
`tls` secret named `langsmith-tls`. This module has **no cert-manager**; create the secret with
the vendored helper, which by default generates a **self-signed** certificate:

```bash
bash modules/azure-private/infra/scripts/create-tls-secret.sh --hostname <your-ingress-hostname>
kubectl -n langsmith get secret langsmith-tls   # confirm it exists
```

> **⚠️ Self-signed = testing/demo only.** The generated certificate is **not trusted** by
> browsers or clients. For production, replace `langsmith-tls` with a real certificate from your
> own CA — for example one exported from Azure Key Vault:
> `create-tls-secret.sh --cert tls.crt --key tls.key`, or manage the secret yourself. Note the
> open-source `ingress-nginx` this module installs is scheduled for retirement (upstream
> maintenance ends **March 2026**); for a longer-term, Key-Vault-native TLS path consider the AKS
> **Application Routing add-on** or **Application Gateway for Containers**.

Reference the secret in your Helm values: `ingress.tls[].secretName: langsmith-tls`.

### Phase 4 — Install the LangSmith application (Helm)

**This module does not bundle the LangSmith chart or an app-deploy script** (those live in
`modules/azure/helm` / `modules/azure/app`). Install LangSmith with its Helm chart, supplying
values derived from the `infra/` Terraform outputs and the secrets `bootstrap/` already
created in the `langsmith` namespace.

The LangSmith chart is published at `https://langchain-ai.github.io/helm` (chart
`langchain/langsmith`, pinned to the `~0.15.1` line). Two approaches:

> **⚠️ Chart-version alignment.** A couple of things in this module are coupled to the exact
> LangSmith chart version you install here. **Before Phase 4, run the
> [Chart-version compatibility](#chart-version-compatibility) checklist** to confirm the module's
> hardcoded service-account names and secret keys match the chart version you pin.

- **Reuse the `modules/azure` Helm tooling against this cluster (recommended).** That module's
  `helm/scripts/init-values.sh` reads Terraform outputs and generates an Azure-specific
  **overrides** values file, then `helm/scripts/deploy.sh` runs the install
  (`helm repo add langchain https://langchain-ai.github.io/helm` → `helm upgrade --install
  langsmith langchain/langsmith --version ~0.15.1`). All the outputs that `init-values.sh`
  consumes **exist in the `infra/` root** — `storage_account_name`, `storage_container_name`,
  `storage_account_k8s_managed_identity_client_id`, `langsmith_namespace`,
  `langsmith_admin_email` — so you can point that tooling at `modules/azure-private/infra` (set
  its `INFRA_DIR` / run it with this module's `terraform.tfvars`) and deploy. Note the base
  `helm/values/examples/langsmith-values.yaml` is **AWS-oriented**; the Azure specifics come
  from the generated overrides, so don't apply that base file unedited.
- **Or install the chart directly:**
  ```bash
  helm repo add langchain https://langchain-ai.github.io/helm
  helm repo update langchain
  helm upgrade --install langsmith langchain/langsmith --version "~0.15.1" \
    -n langsmith -f your-azure-values.yaml
  ```
  Author `your-azure-values.yaml` to wire:
  - **Hostname:** `config.hostname: <your-host>` — the DNS name clients use to reach LangSmith.
    It must resolve to the **private** ingress IP via your internal DNS (see
    [Phase 5](#phase-5--verify--access)). Required when ingress is enabled.
  - **Ingress:** `ingress.enabled: true`, `ingress.ingressClassName: nginx` (the `bootstrap/`
    root installs the internal NGINX controller), and `ingress.tls[].secretName: langsmith-tls`.
  - **Azure Blob:** `config.blobStorage.enabled: true`, `config.blobStorage.engine: "Azure"`,
    `azureStorageAccountName` / `azureStorageContainerName` (from `terraform -chdir=infra
    output`), with **Workload Identity** — leave the account key empty and, for each
    blob-accessing component (`backend`, `platformBackend`, `queue`, `ingestQueue`,
    `hostBackend`, `listener`, and the fleet servers if enabled), set the pod label
    `azure.workload.identity/use: "true"` **and** the ServiceAccount annotation
    `azure.workload.identity/client-id: <storage_account_k8s_managed_identity_client_id>`.
  - **Postgres:** `postgres.external.enabled: true`,
    `postgres.external.existingSecretName: langsmith-postgres-secret`,
    `connectionUrlSecretKey: connection_url`.
  - **Redis:** `redis.external.enabled: true`,
    `redis.external.existingSecretName: langsmith-redis-secret`,
    `connectionUrlSecretKey: connection_url`, and — for Azure Managed Redis —
    `redis.external.clusterSafeMode: true` (see the `redis_cluster_safe_mode` output).
  - **App config:** `config.existingSecretName: langsmith-config-secret` (created in
    [Phase 3.5](#phase-35--create-the-app-config-secret)).

  Confirm the exact value keys against the chart version you install (see the alignment note
  above). Note the recommended `init-values.sh` path emits all of the above automatically.

> **Gap to be aware of:** turnkey app-deploy automation is intentionally not part of this infra
> module yet. See [Known gaps](#known-gaps--follow-ups). For a fully automated path today, the
> general-purpose `modules/azure` (public/managed) module has the full `make deploy` /
> `make apply-app` flow.

### Phase 5 — Verify & access

Check overall health and find the private ingress IP (run from the jumpbox, kubectl pointed at
the cluster):

```bash
bash modules/azure-private/infra/scripts/status.sh      # end-to-end health + next steps

# The internal NGINX load balancer's PRIVATE IP (reachable only from within the VNet):
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
```

**Point your hostname at that private IP using internal DNS.** There is no public DNS record for
a private cluster — map the name you set as `config.hostname` to the private ingress IP via your
Azure Private DNS zone, a conditional forwarder, or (for a quick test) a `/etc/hosts` entry on
the jumpbox. Then reach LangSmith from an in-VNet host:

```bash
# Confirm the ingress serves (self-signed cert → -k). Any 2xx/3xx means frontend is up:
curl -ksS -o /dev/null -w '%{http_code}\n' https://<your-config-hostname>/
# or open https://<your-config-hostname>/ in a browser with VNet access.
```

The certificate warning (`-k` / "not trusted") is expected with the self-signed cert from
[Phase 3.5](#phase-35--create-the-app-config-secret) — replace `langsmith-tls` with a cert from
your own CA to remove it.

**First login (basic auth):** sign in with the initial org admin email (the
`langsmith_admin_email` output / what you set in `setup-env.sh`) and the admin password stored in
Key Vault as `langsmith-admin-password`.

### Teardown
```bash
# Destroy bootstrap/ first (from the jumpbox), then infra/:
# On the jumpbox:
terraform -chdir=modules/azure-private/bootstrap destroy
# Then from anywhere:
terraform -chdir=modules/azure-private/infra destroy
# Purge soft-deleted Key Vaults if keyvault_purge_protection = false:
az keyvault list-deleted --query "[?contains(name,'langsmith-kv')].name" -o tsv | xargs -I{} az keyvault purge -n {}
```

`infra destroy` removes everything the `infra/` root created **inside** your RG; it does not
delete your RG, VNet, subnets, route table, or firewall.

---

## Chart-version compatibility

**The Azure infrastructure is version-agnostic.** Phases 0–3 (`infra/` + `bootstrap/`) provision
the cluster, networking, Postgres/Redis/Blob/Key Vault, internal NGINX, KEDA, and the
connection/config/TLS secrets. None of that depends on the LangSmith chart version — provision it
first, then choose a chart version at Phase 4.

**Two things ARE coupled to the chart version you install in Phase 4** — and a mismatch fails
**silently at runtime**, not at `terraform apply`:

| Coupled thing | Where it lives | If it doesn't match the chart |
|---|---|---|
| Workload-identity **service-account names** (`service_accounts_for_workload_identity`) | `infra/modules/k8s-cluster/main.tf` | The pod's SA has no federated credential → OIDC token exchange fails → **Blob + Key Vault access fails** for that component |
| App-config **secret keys** in `langsmith-config-secret` | `infra/scripts/create-k8s-secrets.sh` (consumed via the chart's `config.existingSecretName`) | The pod can't find `langsmith_license_key` / `api_key_salt` / `jwt_secret` → the app won't start |

The module's `service_accounts_for_workload_identity` list is currently aligned to the LangSmith
chart's **0.16.x** line — e.g. the Fleet SAs are `fleet-tool-server` / `fleet-trigger-server`
(renamed from `agent-builder-*` in older charts). The docs pin `~0.15.1` for the recommended
`modules/azure` tooling path, so **decide which chart version you actually deploy and validate
before Phase 4.**

### Validation checklist (run before Phase 4)

Render the chart version you intend to install and compare it against the module. (`helm template`
may need a few `--set`/`-f` values for the chart to render; add them as needed, or just read the
chart source.)

```bash
CHART_VERSION="<the version you will install, e.g. 0.16.0-rc.6 or 0.15.1>"

# 1. Service-account names the chart renders (blob/KV-accessing components):
helm template langsmith langchain/langsmith --version "$CHART_VERSION" \
  --set config.langsmithLicenseKey=x --set config.apiKeySalt=x \
  --set config.basicAuth.jwtSecret=x 2>/dev/null \
  | awk '/kind: ServiceAccount/{f=1} f&&/name:/{print $2; f=0}' | sort -u
#   → compare to service_accounts_for_workload_identity in
#     infra/modules/k8s-cluster/main.tf (federated subject = system:serviceaccount:<ns>:<name>)

# 2. Secret keys the chart reads from the config secret:
helm template langsmith langchain/langsmith --version "$CHART_VERSION" \
  --set config.langsmithLicenseKey=x --set config.apiKeySalt=x \
  --set config.basicAuth.jwtSecret=x 2>/dev/null \
  | grep -oE 'key: (langsmith_license_key|api_key_salt|jwt_secret|[a-z_]+encryption_key)' | sort -u
#   → compare to the --from-literal keys in infra/scripts/create-k8s-secrets.sh
```

Or read the chart source directly: component `name:` fields in `values.yaml`, and the keys in
`templates/secrets.yaml` / `templates/_helpers.tpl`.

**If something differs from what the module encodes:**
- **SA names** → edit `service_accounts_for_workload_identity` in
  `infra/modules/k8s-cluster/main.tf` and re-apply `infra/`. Cheap and non-destructive — it only
  adds/renames `azurerm_federated_identity_credential` resources; the cluster and data are untouched.
- **Secret keys** → edit the `--from-literal` key names in `infra/scripts/create-k8s-secrets.sh`
  and re-run it.

Then install with your validated version:
`helm upgrade --install langsmith langchain/langsmith --version "$CHART_VERSION" ...`.

---

## No `make` pattern (vs `modules/azure`)

`modules/azure` ships a `Makefile` plus `helm/` and `app/` directories that wrap a 5-pass
workflow (`make apply` → `make kubeconfig` → `make k8s-secrets` → `make deploy`). **This module
deliberately does not.** It has two Terraform roots (`infra/` + `bootstrap/`) and the
`infra/scripts/` helpers. Map the familiar `make` targets to direct commands here:

| `modules/azure` (`make …`) | `modules/azure-private` |
|---|---|
| `make preflight` | `bash infra/scripts/preflight.sh` |
| `make setup-env` | `bash infra/scripts/setup-env.sh` |
| `make init` / `plan` / `apply` | `terraform -chdir=infra init` / `plan` / `apply` (or `bash infra/scripts/tf-run.sh …`) |
| `make kubeconfig` | `az aks get-credentials …` (from the in-VNet host) |
| in-cluster bootstrap (namespace, RBAC, Postgres/Redis secrets, KEDA, NGINX) | `terraform -chdir=bootstrap apply` (from the jumpbox) |
| `make k8s-secrets` (app-config secret) | `bash infra/scripts/create-k8s-secrets.sh` (from the jumpbox, [Phase 3.5](#phase-35--create-the-app-config-secret)) |
| TLS secret (self-signed / BYO) | `bash infra/scripts/create-tls-secret.sh` (from the jumpbox, [Phase 3.5](#phase-35--create-the-app-config-secret)) |
| `make status` | `bash infra/scripts/status.sh` |
| `make deploy` (LangSmith Helm) | **not bundled** — see [Phase 4](#phase-4--install-the-langsmith-application-helm) |
| `make destroy` / `make clean` | `terraform -chdir=bootstrap destroy` → `terraform -chdir=infra destroy` / `bash infra/scripts/clean.sh` |

The `infra/scripts/` helpers (`preflight.sh`, `setup-env.sh`, `create-k8s-secrets.sh`,
`create-tls-secret.sh`, `status.sh`, `tf-run.sh`, `manage-keyvault.sh`, `clean.sh`) were
vendored with the infra and work standalone — they do not require `make`.

---

## What runs in the cluster (bootstrap/ root)

The `bootstrap/` root installs the following in-cluster components. Everything is discovered
from Azure (data sources + Key Vault) — `bootstrap/` does not import from the `infra/` state:

| Component | Installed by |
|---|---|
| KEDA | `bootstrap/` (`helm_release`) |
| NGINX ingress controller (internal LB, private IP) | `bootstrap/` (`helm_release`) |
| `langsmith` namespace | `bootstrap/` (`kubernetes_namespace`) |
| Postgres/Redis connection K8s secrets (`langsmith-postgres-secret`, `langsmith-redis-secret`) | `bootstrap/` (reads from Key Vault) |
| App-config K8s secret (`langsmith-config-secret`) | `create-k8s-secrets.sh` ([Phase 3.5](#phase-35--create-the-app-config-secret), reads from Key Vault) |
| TLS K8s secret (`langsmith-tls`) | `create-tls-secret.sh` ([Phase 3.5](#phase-35--create-the-app-config-secret), self-signed by default) |

There is **no cert-manager** — TLS is a script-created secret (self-signed for testing, BYO for
production). See [Phase 3.5](#phase-35--create-the-app-config-secret).

---

## Key gotchas

- **Egress must work before/at apply.** UDR + no public egress means a misconfigured firewall
  route ⇒ node provisioning failure, not a clean error. Validate the route + firewall rules first.
- **`infra/` is always safe to run from anywhere.** It has no Kubernetes or Helm providers.
  The private API server is not a blocker for `infra/` applies.
- **`bootstrap/` must run from the jumpbox.** The Kubernetes and Helm providers need to reach
  the private API server. SSH to the jumpbox, get credentials, then apply.
- **ClickHouse runs in-cluster.** The chart bundles ClickHouse (a StatefulSet on a PVC using
  the AKS default StorageClass) — this module does **not** provision a managed ClickHouse. Size
  the node pool and the `bootstrap` `ResourceQuota` (default 40 CPU / 80 GiB requests) so the
  bundled ClickHouse **plus** all LangSmith components fit, or pods are rejected with
  quota-exceeded. Bump the quota / node `max_count` for anything beyond a base install.
- **Postgres/Redis subnets are Private-Endpoint subnets, not delegated.**
- **VNet injection vs Private Endpoint is immutable** on Flexible Server; this module is PE by
  design.
- **Switching `aks_private_cluster_enabled`/overlay/UDR after creation is destructive** — these
  are hardcoded here precisely because they're create-time decisions.

---

## Known gaps / follow-ups

These are tracked items, not blockers, surfaced during the build review:

1. **No bundled LangSmith app deploy.** Phase 4 is manual today. A follow-up could vendor a
   trimmed `helm/` (values + deploy script) or an `app/` Terraform path tailored to internal
   NGINX, so this module offers a turnkey deploy like `modules/azure`.
2. **Bastion SSH allowlist defaults open.** `bastion_allowed_ssh_cidrs` defaults to
   `0.0.0.0/0`. For a hardened landing zone, set it to your operator/runner CIDR (the jumpbox
   has a public IP). Consider this required hardening.
3. **Dead ingress code.** `k8s-cluster` still carries unreachable istio/istio-addon/
   envoy-gateway branches (the module is pinned to internal NGINX). Harmless; a cleanup candidate.
4. **TLS is self-signed by default.** `create-tls-secret.sh` mints a self-signed cert for the
   `langsmith-tls` secret — testing only. Production must supply a real cert (`--cert/--key`, e.g.
   from Key Vault) or adopt a Key-Vault-native managed ingress. The bundled OSS `ingress-nginx`
   is itself scheduled for upstream retirement (**March 2026**) — a future migration to the AKS
   Application Routing add-on or Application Gateway for Containers is the longer-term path.
