# LangSmith Azure Deployment Standardization Plan

## Problem Statement

The current 5-pass deployment model routes **every** pass through `terraform apply`, coupling
application lifecycle to infrastructure lifecycle. Helm values are embedded in Terraform HCL as
`yamlencode()` locals, `null_resource` bootstrap scripts are opaque and non-idempotent, and
`setup-env.sh` is a 338-line monolith mixing secret management, deployment flags, and hostname
detection. The `helm/scripts/` directory exists with well-designed scripts that are currently unused.

## Target Architecture

```
Pass 1 — Infrastructure (Terraform only)
  What:  VNet · AKS · Postgres · Redis · Blob · Key Vault
         cert-manager · KEDA · namespace · ServiceAccount · K8s infra secrets
  How:   source infra/setup-env.sh   (slim — infra vars only)
         terraform apply

Pass 1.5 — Cluster Access
  How:   bash helm/scripts/get-kubeconfig.sh <cluster> <rg>

Pass 1.6 — TLS Cluster Issuers (if using Let's Encrypt)
  How:   ACME_EMAIL=you@example.com bash helm/scripts/apply-cluster-issuers.sh

Pass 2 — LangSmith (Helm)
  What:  LangSmith application stack
  How:   bash helm/scripts/generate-secrets.sh      # writes K8s secrets + values-overrides.yaml
         bash helm/scripts/deploy.sh                # helm upgrade --install

Pass 3 — LangGraph Deployments (Helm overlay)
  How:   bash helm/scripts/deploy.sh --overlay overlays/deployments.yaml

Pass 4 — Agent Builder (Helm overlay + bootstrap)
  How:   bash helm/scripts/deploy.sh --overlay overlays/deployments.yaml \
                                     --overlay overlays/agent-builder.yaml
         bash helm/scripts/bootstrap-agent-builder.sh

Pass 5 — Insights (Helm overlay + bootstrap)
  How:   bash helm/scripts/deploy.sh --overlay overlays/deployments.yaml \
                                     --overlay overlays/insights.yaml
         bash helm/scripts/bootstrap-insights.sh
```

## Before vs After: Pass Structure

| | Before | After |
|---|---|---|
| Pass 1 | `source setup-env.sh; terraform apply` | `source setup-env.sh; terraform apply` (slimmer) |
| Pass 2 | `source setup-env.sh --deploy; terraform apply` | `generate-secrets.sh; deploy.sh` |
| Pass 3 | `source setup-env.sh --deploy --enable-deployments; terraform apply` | `deploy.sh --overlay overlays/deployments.yaml` |
| Pass 4 | `source setup-env.sh --deploy --enable-deployments --enable-agent-builder; terraform apply` | `deploy.sh --overlay ...; bootstrap-agent-builder.sh` |
| Pass 5 | `source setup-env.sh --deploy ... --enable-insights; terraform apply` | `deploy.sh --overlay ...; bootstrap-insights.sh` |

## File Inventory

### Created (New Files)

| File | Purpose |
|------|---------|
| `helm/values/values-overrides-demo.yaml.example` | Template operators copy → `values-overrides.yaml` |
| `helm/values/overlays/deployments.yaml` | Pass 3: LangGraph Platform overlay |
| `helm/values/overlays/agent-builder.yaml` | Pass 4: Agent Builder overlay |
| `helm/values/overlays/insights.yaml` | Pass 5: Insights overlay |
| `kubectl/letsencrypt-issuers.yaml` | ClusterIssuer manifests (staging + prod) |
| `kubectl/rbac-bootstrap.yaml` | Role + RoleBinding for agent/insights bootstrap |
| `helm/scripts/apply-cluster-issuers.sh` | Wait for cert-manager CRD + apply ClusterIssuers |
| `helm/scripts/bootstrap-agent-builder.sh` | Agent Builder bootstrap (extracted from Terraform null_resource) |
| `helm/scripts/bootstrap-insights.sh` | Insights bootstrap (extracted from Terraform null_resource) |

### Modified (Existing Files)

| File | Change |
|------|--------|
| `infra/modules/k8s-bootstrap/main.tf` | **Remove**: `helm_release.langsmith`, all `null_resource`, RBAC Role/Binding, entire `locals {}` block. **Keep**: namespace, SA, quota, network policies, cert-manager, KEDA, K8s secrets |
| `infra/modules/k8s-bootstrap/variables.tf` | Remove 20 app-deployment variables, keep 10 infra variables |
| `infra/main.tf` | Remove app-deployment vars from `k8s_bootstrap` module call; update header comments |
| `infra/variables.tf` | Remove `deploy_langsmith`, `langsmith_hostname`, `langsmith_admin_email`, `langsmith_version`, `tls_certificate_source`, `acme_email`, `blob_storage_account_key`, `enable_*` feature flags |
| `helm/scripts/deploy.sh` | Add `--overlay` flag support for multiple value overlays |
| `helm/scripts/generate-secrets.sh` | Expand: read from Key Vault + TF outputs, write all K8s secrets, populate `values-overrides.yaml` |
| `infra/setup-env.sh` | Slim down: remove deploy flags, hostname detection, blob key fetch. Mark deprecated with pointer to new scripts |

### Documentation Updated

- `README.md` — New pass structure, new script commands
- `QUICK_REFERENCE.md` — Updated step-by-step commands
- `ARCHITECTURE.md` — Updated pass descriptions and component diagram

## Terraform: What Moves Where

### Removed from `k8s-bootstrap` → Moved to Scripts/YAML

| Terraform Resource | Moved To |
|-------------------|----------|
| `helm_release.langsmith` | `helm/scripts/deploy.sh` + `helm/values/values-overrides.yaml` |
| `null_resource.letsencrypt_issuers` | `helm/scripts/apply-cluster-issuers.sh` + `kubectl/letsencrypt-issuers.yaml` |
| `null_resource.agent_builder_bootstrap` | `helm/scripts/bootstrap-agent-builder.sh` |
| `null_resource.insights_bootstrap` | `helm/scripts/bootstrap-insights.sh` |
| `kubernetes_role_v1.backend_bootstrap` | `kubectl/rbac-bootstrap.yaml` |
| `kubernetes_role_binding_v1.backend_bootstrap` | `kubectl/rbac-bootstrap.yaml` |

### Stays in Terraform (k8s-bootstrap)

- `kubernetes_namespace_v1.langsmith` — namespace with Workload Identity labels
- `kubernetes_service_account_v1.langsmith` — `langsmith-ksa` with managed identity annotation
- `kubernetes_resource_quota_v1.langsmith` — namespace resource limits
- `kubernetes_network_policy_v1.*` — default-deny + allow-from-ingress-nginx
- `kubernetes_secret_v1.postgres` — connection URL (infrastructure dependency)
- `kubernetes_secret_v1.redis` — connection URL (infrastructure dependency)
- `kubernetes_secret_v1.license` — license key from Key Vault
- `helm_release.cert_manager` — TLS automation infrastructure
- `helm_release.keda` — autoscaling infrastructure

## Migration: Existing Deployments

If you have an existing Terraform state with the old Helm release and null_resources, you need to
remove those resources from state before running `terraform apply` with the new code:

```bash
# Remove LangSmith Helm release from Terraform state (it stays deployed)
terraform state rm module.k8s_bootstrap.helm_release.langsmith[0]

# Remove null resources (they don't create real cloud resources)
terraform state rm module.k8s_bootstrap.null_resource.letsencrypt_issuers[0]
terraform state rm module.k8s_bootstrap.null_resource.agent_builder_bootstrap[0]
terraform state rm module.k8s_bootstrap.null_resource.insights_bootstrap[0]

# Remove RBAC resources (kept as kubectl/rbac-bootstrap.yaml)
terraform state rm module.k8s_bootstrap.kubernetes_role_v1.backend_bootstrap[0]
terraform state rm module.k8s_bootstrap.kubernetes_role_binding_v1.backend_bootstrap[0]
```

## Implementation Phases

### Phase 1: Create New File Structure (this PR)
1. Create `helm/values/values-overrides-demo.yaml.example`
2. Create `helm/values/overlays/*.yaml` (3 files)
3. Create `kubectl/*.yaml` (2 files)
4. Create new scripts in `helm/scripts/` (3 files)

### Phase 2: Simplify Terraform
5. Rework `infra/modules/k8s-bootstrap/main.tf`
6. Rework `infra/modules/k8s-bootstrap/variables.tf`
7. Update `infra/main.tf` module call
8. Update `infra/variables.tf`

### Phase 3: Update Existing Scripts
9. Expand `helm/scripts/generate-secrets.sh`
10. Update `helm/scripts/deploy.sh` (overlay support)
11. Slim down `infra/setup-env.sh`

### Phase 4: Documentation
12. Update `README.md`
13. Update `QUICK_REFERENCE.md`
14. Update `ARCHITECTURE.md`
