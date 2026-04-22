# LangSmith Azure — Task Runner
#
# First time?              make quickstart → make setup-env → make preflight → make init → make apply
# Pass 1 (infra):          make setup-env → make init → make plan → make apply
# Pass 1.5 (access):       make kubeconfig → make k8s-secrets
# Pass 2 (helm):           make init-values → make deploy
# Pass 2 (terraform helm): make init-app → make apply-app
# Full deploy (helm):      make deploy-all
# Full deploy (terraform): make deploy-all-tf
# Manage secrets:          make keyvault
# Where am I?              make status

.PHONY: help quickstart setup-env preflight keyvault status status-quick \
        init plan apply destroy \
        kubeconfig k8s-secrets \
        init-values deploy uninstall deploy-all \
        init-app plan-app apply-app destroy-app deploy-all-tf \
        clean

INFRA_DIR := infra
HELM_DIR  := helm
APP_DIR   := app

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

quickstart: ## Interactive setup wizard — generates terraform.tfvars
	$(INFRA_DIR)/scripts/quickstart.sh

keyvault: ## Interactive Key Vault secret manager (list/get/set/validate/diff/delete)
	$(INFRA_DIR)/scripts/manage-keyvault.sh

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

apply: ## terraform apply (infra) — two-stage: Azure infra first, then k8s bootstrap + ClusterIssuer
	@if [ ! -f $(INFRA_DIR)/secrets.auto.tfvars ]; then cd $(INFRA_DIR) && bash scripts/setup-env.sh; fi
	@echo "→ Stage 1: Azure infrastructure (RG, VNet, AKS, Postgres, Redis, Blob, KeyVault)..."
	terraform -chdir=$(INFRA_DIR) apply -auto-approve \
		-target=azurerm_resource_group.resource_group \
		-target=module.vnet \
		-target=module.aks \
		-target=module.postgres \
		-target=module.redis \
		-target=module.blob \
		-target=module.keyvault
	@echo "→ Stage 2: Kubernetes bootstrap (namespace, secrets, cert-manager, KEDA)..."
	terraform -chdir=$(INFRA_DIR) apply -auto-approve \
		-target=module.k8s_bootstrap.kubernetes_namespace_v1.langsmith \
		-target=module.k8s_bootstrap.kubernetes_service_account_v1.langsmith \
		-target=module.k8s_bootstrap.kubernetes_resource_quota_v1.langsmith \
		-target=module.k8s_bootstrap.kubernetes_network_policy_v1.langsmith_default_deny \
		-target=module.k8s_bootstrap.kubernetes_network_policy_v1.langsmith_allow_internal \
		-target=module.k8s_bootstrap.kubernetes_secret_v1.postgres \
		-target=module.k8s_bootstrap.kubernetes_secret_v1.redis \
		-target=module.k8s_bootstrap.kubernetes_secret_v1.license \
		-target=module.k8s_bootstrap.helm_release.cert_manager \
		-target=module.k8s_bootstrap.helm_release.keda
	@echo "→ Stage 3: ClusterIssuer + remaining resources (cert-manager CRDs now ready)..."
	terraform -chdir=$(INFRA_DIR) apply -auto-approve

destroy: ## terraform destroy (infra) — prompts for confirmation
	terraform -chdir=$(INFRA_DIR) destroy

destroy-force: ## terraform destroy without confirmation prompt (use after make uninstall)
	terraform -chdir=$(INFRA_DIR) destroy -auto-approve

clean: ## Remove all local secrets and generated files (run after destroy)
	$(INFRA_DIR)/scripts/clean.sh

clean-force: ## Remove all local secrets and generated files without confirmation
	echo "y" | $(INFRA_DIR)/scripts/clean.sh

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

# ── Pass 2: App (Terraform Helm) ──────────────────────────────────────────────

init-app: ## Pull infra outputs → app/infra.auto.tfvars.json, then terraform init (app)
	$(APP_DIR)/scripts/pull-infra-outputs.sh
	terraform -chdir=$(APP_DIR) init -input=false

plan-app: init-app ## terraform plan (app) — auto-pulls infra outputs first
	terraform -chdir=$(APP_DIR) plan

apply-app: ## terraform apply (app)
	terraform -chdir=$(APP_DIR) apply

destroy-app: ## terraform destroy (app)
	terraform -chdir=$(APP_DIR) destroy

# ── Combo Targets ─────────────────────────────────────────────────────────────

deploy-all: apply kubeconfig k8s-secrets init-values deploy ## Full deploy: infra → kubeconfig → secrets → helm

deploy-all-tf: apply init-values init-app apply-app ## Full Terraform deploy: infra apply → init-values → app init+apply
