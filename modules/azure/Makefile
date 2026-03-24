# LangSmith Azure — Task Runner
#
# First time?           make setup-env → make preflight → make init → make apply
# Pass 1 (infra):       make setup-env → make init → make plan → make apply
# Pass 1.5 (access):    make kubeconfig → make k8s-secrets
# Pass 2 (helm):        make init-values → make deploy
# Full deploy:          make deploy-all
# Where am I?           make status

.PHONY: help setup-env preflight status status-quick \
        init plan apply destroy \
        kubeconfig k8s-secrets \
        init-values deploy uninstall deploy-all \
        clean

INFRA_DIR := infra
HELM_DIR  := helm

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

status: ## Check deployment state and show what to run next
	$(INFRA_DIR)/scripts/status.sh

status-quick: ## Quick status check (skip Key Vault and K8s queries)
	$(INFRA_DIR)/scripts/status.sh --quick

# ── Pass 1: Infrastructure ────────────────────────────────────────────────────

setup-env: ## Bootstrap secrets → secrets.auto.tfvars (prompts on first run, reads KV on repeat)
	cd $(INFRA_DIR) && bash scripts/setup-env.sh

preflight: ## Run Azure pre-flight checks (login, providers, RBAC, terraform.tfvars)
	cd $(INFRA_DIR) && bash scripts/preflight.sh

init: ## terraform init (infra)
	terraform -chdir=$(INFRA_DIR) init

plan: ## terraform plan (infra) — runs setup-env.sh first to ensure secrets.auto.tfvars exists
	@if [ ! -f $(INFRA_DIR)/secrets.auto.tfvars ]; then cd $(INFRA_DIR) && bash scripts/setup-env.sh; fi
	terraform -chdir=$(INFRA_DIR) plan

apply: ## terraform apply (infra) — runs setup-env.sh first to ensure secrets.auto.tfvars exists
	@if [ ! -f $(INFRA_DIR)/secrets.auto.tfvars ]; then cd $(INFRA_DIR) && bash scripts/setup-env.sh; fi
	terraform -chdir=$(INFRA_DIR) apply -auto-approve

destroy: ## terraform destroy (infra)
	terraform -chdir=$(INFRA_DIR) destroy

clean: ## Remove all local secrets and generated files (run after destroy)
	$(INFRA_DIR)/scripts/clean.sh

# ── Pass 1.5: Cluster Access + K8s Secrets ────────────────────────────────────

kubeconfig: ## Fetch AKS credentials into ~/.kube/config
	$(HELM_DIR)/scripts/get-kubeconfig.sh

k8s-secrets: ## Create langsmith-config-secret from Key Vault (all 8 keys)
	cd $(INFRA_DIR) && bash scripts/create-k8s-secrets.sh

# ── Pass 2+: Helm Deployment ─────────────────────────────────────────────────

init-values: ## Generate Helm values from Terraform outputs (run after terraform apply)
	$(HELM_DIR)/scripts/init-values.sh

deploy: ## Deploy LangSmith via Helm (values chain: base + overrides + sizing + addons)
	$(HELM_DIR)/scripts/deploy.sh

uninstall: ## Uninstall LangSmith Helm release
	$(HELM_DIR)/scripts/uninstall.sh

# ── Combo Targets ─────────────────────────────────────────────────────────────

deploy-all: apply kubeconfig k8s-secrets init-values deploy ## Full deploy: infra → kubeconfig → secrets → helm
