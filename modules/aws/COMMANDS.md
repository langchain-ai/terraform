# LangSmith on AWS — Make Target Glossary

All commands run from `terraform/aws/`. Run `make help` for a quick inline summary.

---

## Setup

| Command | Description |
|---------|-------------|
| `make quickstart` | Interactive wizard — generates `infra/terraform.tfvars` (region, node size, TLS method, addons) |
| `make setup-env` | Prints the `source` command needed to load secrets into your shell; cannot export variables directly (Make subshell limitation) |
| `make secrets` | Show SSM secrets status and shell export guidance — prints `✓ SET` / `✗ MISSING` per parameter, checks `TF_VAR_*` export status, gives actionable next steps |
| `make secrets-list` | List all SSM parameters for this deployment with last-modified timestamps |

---

## Preflight

| Command | Description |
|---------|-------------|
| `make preflight` | Pre-Terraform preflight — verifies AWS credentials, IAM permissions, and required CLI tools |
| `make preflight-post` | Post-infra preflight (run after `make apply`) — checks kubectl context, cluster reachability, SSM params populated, Helm values files present, TLS config |
| `make preflight-ssm` | Check SSM params only — narrower scope than `preflight-post`; run after `make setup-env` to confirm all parameters are in SSM before `make plan` |

---

## Infrastructure (Pass 1)

| Command | Description |
|---------|-------------|
| `make init` | `terraform init` — downloads providers and modules; safe to re-run |
| `make plan` | `terraform plan` — previews changes; review before every apply |
| `make apply` | `terraform apply` — provisions VPC, EKS, RDS, ElastiCache, S3, ALB, IRSA (~20–25 min) |
| `make destroy` | `terraform destroy` — tears down all infrastructure; run `make uninstall` first |

---

## Helm Deploy (Pass 2)

| Command | Description |
|---------|-------------|
| `make init-values` | Generate `helm/values/langsmith-values-overrides.yaml` from Terraform outputs; copy addon values files based on `enable_*` flags |
| `make deploy` | Deploy or upgrade LangSmith via Helm — runs preflight, ESO sync, values chain build, and core readiness checks |
| `make apply-eso` | Re-apply ESO `ClusterSecretStore` and `ExternalSecret` only — use after rotating secrets without a full Helm redeploy |
| `make uninstall` | Uninstall the LangSmith Helm release; leaves Terraform infrastructure intact |

---

## Terraform App (Pass 2 alt)

| Command | Description |
|---------|-------------|
| `make init-app` | Pull live infra Terraform outputs into `app/infra.auto.tfvars.json` |
| `make plan-app` | `terraform plan` for the `app/` module (auto-runs `init-app` first) |
| `make apply-app` | Deploy LangSmith Helm release via Terraform (`app/` module) |
| `make destroy-app` | Destroy the Helm release via Terraform; leaves infrastructure intact |

---

## Fast Path

| Command | Description |
|---------|-------------|
| `make quickdeploy` | Full deploy in one command — chains `terraform apply` → `kubeconfig` → `init-values` → `helm deploy` with gates; requires `source infra/scripts/setup-env.sh` + `make quickstart` first |
| `make quickdeploy-auto` | Same as `quickdeploy` but non-interactive — passes `-auto-approve` to terraform; use in automation |
| `make deploy-all` | `make apply` → `make kubeconfig` → `make init-values` → `make deploy` in sequence |
| `make deploy-all-tf` | `make apply` → `make init-values` → Terraform `app/` plan+apply in sequence |

---

## Utilities

| Command | Description |
|---------|-------------|
| `make status` | Check deployment state across all 10 layers and show what to run next |
| `make status-quick` | Same as `status` but skips SSM and K8s queries (faster, for shell credential checks) |
| `make kubeconfig` | Update `~/.kube/config` with EKS cluster credentials (`aws eks update-kubeconfig`) |
| `make ssm` | Interactive SSM parameter manager — view, set, rotate, validate, diff vs K8s secret |
| `make tls` | BYO ACM cert + Route53 A alias — use when `langsmith_domain` is set and you need DNS wiring |
| `make clean` | Remove all local generated and sensitive files (run after `make destroy`) |

---

## Testing

| Command | Description |
|---------|-------------|
| `make test-e2e` | Run end-to-end gateway tests (ALB or Envoy Gateway) against the current cluster |
| `make test-permutations` | Run permutation tests sequentially on the current cluster; use `ARGS="1 2 5"` to run a subset |
| `make test-parallel` | Run permutation tests in parallel across isolated clusters — your cluster is untouched |
