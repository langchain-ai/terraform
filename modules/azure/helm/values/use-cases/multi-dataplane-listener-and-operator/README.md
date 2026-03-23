# Multi-Dataplane — Listener + Operator Per Namespace

## Overview

This use case deploys each LangGraph dataplane in its own isolated Kubernetes namespace,
with both an independent listener and an independent operator per workspace. It is the
recommended pattern for Azure deployments that need multi-workspace isolation.

This pattern requires Istio addon (not NGINX ingress) because:
- VirtualService resources route traffic across namespaces to agent deployments
- Standard Ingress is namespace-scoped and cannot route to agents in other namespaces
- Istio Gateway provides the single entry point that spans all dataplane and agent namespaces

## Prerequisites

- `terraform apply` for Pass 1 complete (AKS, networking, managed identity, KEDA, cert-manager)
- Istio addon enabled on the AKS cluster (`ingress_controller = "istio-addon"` in `terraform.tfvars`)
- Istio Gateway and TLS certificate provisioned (see `use-cases/istio/` and `use-cases/nfcu/istio-gateway.yaml`)
- LangSmith Helm chart version `<VERSION>` (all dataplane releases must match — see CRD section below)
- KEDA installed (done by Pass 1 Terraform)
- LangSmith control plane deployed (Pass 2) and healthy before installing dataplanes

---

## Key Findings

### 1. Operator leader election lease is namespace-scoped (validated 2026-03-16)

When the operator runs in namespace `langgraph-dataplane-ws3`, it acquires:
```
langgraph-dataplane-ws3/b578d67b.langchain.ai
```
Not `langsmith/b578d67b.langchain.ai`. Each operator in its own namespace
gets a fully independent lease and becomes active immediately — no competition
with operators in other namespaces.

This means the isolated namespace model is fully viable. Each workspace
gets its own independent operator. A failure in ws1's operator does not
affect ws2 or ws3.

### 2. LGP CRD is cluster-scoped — all operators share one definition

The `LangGraphPlatform` CustomResourceDefinition (`langgraphplatforms.apps.langchain.ai`)
is a cluster-scoped Kubernetes resource. There is exactly **one** CRD installed
on the cluster regardless of how many operators are running.

**Consequence: all dataplanes must run the same chart version.**

If ws1 is upgraded to a chart that changes the LGP CRD schema, ws2 and ws3
operators are now reconciling CRs against a schema they were not built for.
This can cause silent mis-reconciliation or outright errors.

**This is why all values files have `createCRDs: false`:**
```yaml
operator:
  createCRDs: false   # CRD is cluster-scoped — only install once, never let
                      # individual operators fight over it
```

CRDs must be managed separately — either by a dedicated CRD install job or by
designating one release as the CRD owner and keeping all releases in sync on
chart version. In production, manage CRDs via a separate helm install:
```bash
helm upgrade --install langsmith-crds langchain/langgraph-dataplane \
  --set operator.createCRDs=true \
  --set operator.enabled=false \
  --namespace langsmith
```

Then upgrade all three dataplane releases together when the chart version changes.

---

## Architecture

```
langsmith namespace
└── Control Plane only (host-backend, frontend, backend, queue...)
    No listener. No operator.

langgraph-dataplane-ws1 namespace
├── listener  → polls workspace 1 queue
├── operator  → lease: langgraph-dataplane-ws1/b578d67b  (independent)
├── redis
└── (agent pods land in agents-build-one via watchNamespaces)

langgraph-dataplane-ws2 namespace
├── listener  → polls workspace 2 queue
├── operator  → lease: langgraph-dataplane-ws2/b578d67b  (independent)
├── redis
└── (agent pods land in agents-build-two)

langgraph-dataplane-ws3 namespace
├── listener  → polls workspace 3 queue
├── operator  → lease: langgraph-dataplane-ws3/b578d67b  (independent)
├── redis
└── (agent pods land in agents-build-three)

Istio Gateway (<your-domain.com>)
└── VirtualServices route all traffic — CP, agents-build-one, agents-build-two, agents-build-three
```

---

## RBAC

### Overview — what the Helm chart manages vs what you manage

| Resource | Namespace | Managed by |
|---|---|---|
| Operator leader election Role + RoleBinding | `langgraph-dataplane-wsN` | **Helm chart** (langgraph-dataplane) |
| Operator Role + RoleBinding in agent namespace | `agents-build-N` | **Helm chart** (langgraph-dataplane) |
| Listener Role + RoleBinding in agent namespace | `agents-build-N` | **Helm chart** (langgraph-dataplane) |
| `host-backend-pod-reader` Role + RoleBinding | `agents-build-N` | **You** — applied separately |

The dataplane Helm chart handles everything it needs to operate. The only thing
you must apply manually is the `host-backend` log-access binding.

---

### Dataplane RBAC — created automatically by the Helm chart

When you install `langgraph-dataplane-wsN` with `watchNamespaces: "agents-build-N"`,
the chart creates three sets of RBAC automatically:

**1. In the dataplane namespace (`langgraph-dataplane-wsN`) — leader election**

Allows the operator pod to manage its own namespace-scoped lease:

```
Role: langgraph-dataplane-wsN-operator-leader-election-role
  - coordination.k8s.io/leases     → get, list, watch, create, update, patch, delete
  - configmaps                     → get, list, watch, create, update, patch, delete
  - events                         → create, patch

RoleBinding → SA: langgraph-dataplane-wsN-operator (in langgraph-dataplane-wsN)
```

This is why the lease is namespace-scoped — the operator only has permission
to create/update leases in its own namespace, not in `langsmith` or anywhere else.

**2. In the agent namespace (`agents-build-N`) — operator permissions**

Allows the operator to reconcile LGP CRDs into full running workloads:

```
Role: langgraph-dataplane-wsN-operator
  - apps/deployments, statefulsets  → full CRUD
  - apps/replicasets                → read
  - apps.langchain.ai/lgps          → full CRUD  ← watches for new agent deployments
  - pods, services, serviceaccounts → full CRUD
  - pods/log                        → read
  - autoscaling/hpa                 → full CRUD
  - keda.sh/scaledobjects           → full CRUD
  - networking.istio.io/virtualservices → full CRUD  ← creates Istio routes per agent

RoleBinding → SA: langgraph-dataplane-wsN-operator (in langgraph-dataplane-wsN)
```

**3. In the agent namespace (`agents-build-N`) — listener permissions**

Allows the listener to create the secrets and LGP CRDs that trigger the operator:

```
Role: langgraph-dataplane-wsN-listener
  - secrets                         → full CRUD  ← creates ${name}-secrets
  - apps.langchain.ai/lgps          → full CRUD  ← creates the LGP CRD
  - apps/deployments, statefulsets  → full CRUD
  - services                        → full CRUD
  - persistentvolumeclaims          → list, delete

RoleBinding → SA: langgraph-dataplane-wsN-listener (in langgraph-dataplane-wsN)
```

Note that both the operator and listener SAs live in the **dataplane namespace**
but their Roles and RoleBindings are created in the **agent namespace**. This is
standard Kubernetes cross-namespace RoleBinding — the subject is in one namespace,
the permission is scoped to another.

---

### host-backend RBAC — you apply this

#### Why RBAC is needed

`host-backend` (in the `langsmith` namespace) needs to read pod logs from
each `agents-build-*` namespace so they surface in the LangSmith UI. Without
this, the UI shows "Unable to retrieve server logs" for agent deployments.

**Applies to `agents-build-*` only — not to `langgraph-dataplane-wsN`.**
Dataplane namespaces hold listener/operator infrastructure pods; their logs
are not user-facing and do not need to surface in the UI.

This is the **only** cross-namespace permission required. The operator creates
agent pods in `agents-build-*` directly; it does not need RBAC for that because
it runs with its own service account that has permissions granted by the helm chart.

#### What is applied

One `Role` + one `RoleBinding` per agent namespace:

```yaml
# Role — defined once per agents-build-* namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: host-backend-pod-reader
  namespace: agents-build-one   # repeat for agents-build-two, agents-build-three
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
---
# RoleBinding — grants langsmith/langsmith-host-backend access to this namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: host-backend-pod-reader
  namespace: agents-build-one
subjects:
- kind: ServiceAccount
  name: langsmith-host-backend   # SA lives in langsmith namespace
  namespace: langsmith
roleRef:
  kind: Role
  name: host-backend-pod-reader
  apiGroup: rbac.authorization.k8s.io
```

#### Apply

```bash
kubectl apply -f terraform/azure/helm/values/use-cases/multi-dataplane-listener-and-operator/host-backend-rbac.yaml

# Verify
kubectl auth can-i get pods/log -n agents-build-one \
  --as=system:serviceaccount:langsmith:langsmith-host-backend
# → yes

kubectl auth can-i get pods/log -n agents-build-two \
  --as=system:serviceaccount:langsmith:langsmith-host-backend
# → yes

kubectl auth can-i get pods/log -n agents-build-three \
  --as=system:serviceaccount:langsmith:langsmith-host-backend
# → yes
```

#### Adding a new workspace namespace

When adding `agents-build-four`, apply the Role + RoleBinding in that namespace
before deploying agents. No changes to existing namespaces needed.

#### What the Helm chart manages vs what you manage

| Resource | Managed by |
|---|---|
| `langsmith-host-backend-role` in `langsmith` ns | Helm chart (langsmith/langsmith) |
| `host-backend-pod-reader` Role in `agents-build-*` | **You** — applied manually or via Terraform |
| `host-backend-pod-reader` RoleBinding in `agents-build-*` | **You** — applied manually or via Terraform |

The chart only creates RBAC within its own namespace. Cross-namespace bindings
for agent log access must be provisioned separately.

---

## Compared to Shared-Namespace Model

| | Shared (langsmith ns) | Isolated (this model) |
|---|---|---|
| Operator count | 1 shared, watches all namespaces | 1 per workspace, watches own namespace only |
| Operator failure blast radius | All workspaces | Single workspace |
| Adding a new workspace | Must update ws1 watchNamespaces + re-deploy ws1 | Install new release in new namespace only |
| Leader election | All operators compete for `langsmith/b578d67b` | Each operator has its own `<ns>/b578d67b` |
| Azure Workload Identity | All SAs in `langsmith` ns — one set of federated credentials | Needs federated credentials per namespace |
| Operational complexity | Low | Medium |

---

## What This Model Requires

Three groups of namespaces each need their own setup. Never mix them up.

```
Control Plane (langsmith)           — LangSmith backend, host-backend, frontend
Dataplane (langgraph-dataplane-wsN) — listener + operator per workspace
Agent (agents-build-N)              — agent pods land here (operator writes here)
```

---

## Setup Guide

### Control Plane — `langsmith` namespace

Managed entirely by the LangSmith Helm chart. Nothing to provision manually
except the host-backend RBAC that grants log access into agent namespaces
(see RBAC section above).

---

### Dataplane — `langgraph-dataplane-wsN` namespaces

One namespace per workspace. Each needs:

#### 1. Create isolated namespaces

```bash
kubectl create namespace langgraph-dataplane-ws1
kubectl create namespace langgraph-dataplane-ws2
kubectl create namespace langgraph-dataplane-ws3
```

Removing a dataplane from an existing namespace does NOT delete Postgres
listener records — they are reused by the new install.

#### 2. Add Azure Workload Identity federated credentials

Tells Azure AD to trust k8s tokens issued by this cluster for these service
accounts. Without this, pods in the new namespace cannot authenticate to
ACR or Key Vault — the OIDC token exchange is rejected.

Two credentials are needed per namespace:
- `langgraph-dataplane-wsN-listener` — the listener pod SA (created by helm)
- `langsmith-ksa` — used by the operator pod template for agent pods

```bash
# ── Workspace 1 ──────────────────────────────────────────────────────────────
az identity federated-credential create \
  --name "langsmith-federated-langgraph-dataplane-ws1-listener" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:langgraph-dataplane-ws1:langgraph-dataplane-ws1-listener" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "langsmith-federated-langgraph-dataplane-ws1-ksa" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:langgraph-dataplane-ws1:langsmith-ksa" \
  --audiences "api://AzureADTokenExchange"

# ── Workspace 2 ──────────────────────────────────────────────────────────────
az identity federated-credential create \
  --name "langsmith-federated-langgraph-dataplane-ws2-listener" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:langgraph-dataplane-ws2:langgraph-dataplane-ws2-listener" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "langsmith-federated-langgraph-dataplane-ws2-ksa" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:langgraph-dataplane-ws2:langsmith-ksa" \
  --audiences "api://AzureADTokenExchange"

# ── Workspace 3 ──────────────────────────────────────────────────────────────
az identity federated-credential create \
  --name "langsmith-federated-langgraph-dataplane-ws3-listener" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:langgraph-dataplane-ws3:langgraph-dataplane-ws3-listener" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "langsmith-federated-langgraph-dataplane-ws3-ksa" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:langgraph-dataplane-ws3:langsmith-ksa" \
  --audiences "api://AzureADTokenExchange"
```

#### 3. Create `langsmith-ksa` service account in each dataplane namespace

The operator deployment template references `serviceAccountName: langsmith-ksa`.
This SA must exist in the dataplane namespace and be bound to the managed identity.

```bash
kubectl create serviceaccount langsmith-ksa -n langgraph-dataplane-ws1
kubectl annotate serviceaccount langsmith-ksa -n langgraph-dataplane-ws1 \
  azure.workload.identity/client-id="<tf output: workload_identity_client_id>"

kubectl create serviceaccount langsmith-ksa -n langgraph-dataplane-ws2
kubectl annotate serviceaccount langsmith-ksa -n langgraph-dataplane-ws2 \
  azure.workload.identity/client-id="<tf output: workload_identity_client_id>"

kubectl create serviceaccount langsmith-ksa -n langgraph-dataplane-ws3
kubectl annotate serviceaccount langsmith-ksa -n langgraph-dataplane-ws3 \
  azure.workload.identity/client-id="<tf output: workload_identity_client_id>"
```

#### 4. Helm install — each release in its own namespace

```bash
helm upgrade --install langgraph-dataplane-ws1 langchain/langgraph-dataplane \
  --namespace langgraph-dataplane-ws1 \
  --values terraform/azure/helm/values/use-cases/multi-dataplane-listener-and-operator/values-dp-ws1.yaml.example \
  --wait

helm upgrade --install langgraph-dataplane-ws2 langchain/langgraph-dataplane \
  --namespace langgraph-dataplane-ws2 \
  --values terraform/azure/helm/values/use-cases/multi-dataplane-listener-and-operator/values-dp-ws2.yaml.example \
  --wait

helm upgrade --install langgraph-dataplane-ws3 langchain/langgraph-dataplane \
  --namespace langgraph-dataplane-ws3 \
  --values terraform/azure/helm/values/use-cases/multi-dataplane-listener-and-operator/values-dp-ws3.yaml.example \
  --wait
```

#### 5. Verify all leases are independent

```bash
kubectl get lease -n langgraph-dataplane-ws1
# b578d67b.langchain.ai   langgraph-dataplane-ws1-operator-xxx   ...

kubectl get lease -n langgraph-dataplane-ws2
# b578d67b.langchain.ai   langgraph-dataplane-ws2-operator-xxx   ...

kubectl get lease -n langgraph-dataplane-ws3
# b578d67b.langchain.ai   langgraph-dataplane-ws3-operator-xxx   ...
```

**Values files — operator enabled on all, each watches its own agent namespace only**

```yaml
# values-dp-wsN.yaml.example
config:
  watchNamespaces: "agents-build-N"   # only this workspace's agent namespace

operator:
  enabled: true                        # independent per namespace
  createCRDs: false
  kedaEnabled: true
  watchNamespaces: "agents-build-N"
  deployment:
    replicas: 2                        # HA within the namespace
```

No release needs to list other workspaces' namespaces. Adding ws4 is
a new namespace + new Helm install — no existing releases touched.

---

### Agent Namespaces — `agents-build-N`

Agent pods created by the operator use `serviceAccountName: langsmith-ksa`
to pull images from ACR and access Key Vault secrets. The operator does NOT
create this SA — it must be pre-provisioned before any agent can start.

#### Namespaces

```bash
kubectl create namespace agents-build-one
kubectl create namespace agents-build-two
kubectl create namespace agents-build-three
```

#### Azure Workload Identity — federated credentials

One credential per agent namespace (only `langsmith-ksa` — no listener SA here):

```bash
# ── agents-build-one ─────────────────────────────────────────────────────────
az identity federated-credential create \
  --name "langsmith-federated-agents-build-one-ksa" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:agents-build-one:langsmith-ksa" \
  --audiences "api://AzureADTokenExchange"

# ── agents-build-two ─────────────────────────────────────────────────────────
az identity federated-credential create \
  --name "langsmith-federated-agents-build-two-ksa" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:agents-build-two:langsmith-ksa" \
  --audiences "api://AzureADTokenExchange"

# ── agents-build-three ───────────────────────────────────────────────────────
az identity federated-credential create \
  --name "langsmith-federated-agents-build-three-ksa" \
  --identity-name "<managed-identity-name from tf output>" \
  --resource-group "<resource-group>" \
  --issuer "<tf output: aks_oidc_issuer_url>" \
  --subject "system:serviceaccount:agents-build-three:langsmith-ksa" \
  --audiences "api://AzureADTokenExchange"
```

#### `langsmith-ksa` service account in each agent namespace

```bash
kubectl create serviceaccount langsmith-ksa -n agents-build-one
kubectl annotate serviceaccount langsmith-ksa -n agents-build-one \
  azure.workload.identity/client-id="<tf output: workload_identity_client_id>"

kubectl create serviceaccount langsmith-ksa -n agents-build-two
kubectl annotate serviceaccount langsmith-ksa -n agents-build-two \
  azure.workload.identity/client-id="<tf output: workload_identity_client_id>"

kubectl create serviceaccount langsmith-ksa -n agents-build-three
kubectl annotate serviceaccount langsmith-ksa -n agents-build-three \
  azure.workload.identity/client-id="<tf output: workload_identity_client_id>"
```

#### RBAC — host-backend log access

```bash
kubectl apply -f terraform/azure/helm/values/use-cases/multi-dataplane-listener-and-operator/host-backend-rbac.yaml
```

When adding a new agent namespace, add the Role + RoleBinding for that namespace
to `host-backend-rbac.yaml` and re-apply. No changes to existing namespaces needed.

#### Terraform alternative (k8s-bootstrap)

```hcl
variable "agent_namespaces" {
  type    = list(string)
  default = ["agents-build-one", "agents-build-two", "agents-build-three"]
}

resource "kubernetes_service_account_v1" "agent_ksa" {
  for_each = toset(var.agent_namespaces)
  metadata {
    name      = "langsmith-ksa"
    namespace = each.value
    annotations = {
      "azure.workload.identity/client-id" = var.blob_managed_identity_client_id
    }
  }
}
```
