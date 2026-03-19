# LangSmith AWS Deployment — Task Runner
#
# First time?      make quickstart
# Pass 1 (infra):  make setup-env → make init → make plan → make apply
# Pass 2 (helm):   make init-values → make deploy
# Pass 2 (tf):     make init-app → make plan-app → make apply-app
# Full deploy:     make deploy-all
# Where am I?      make status

.PHONY: help quickstart status status-quick setup-env init plan apply \
        preflight kubeconfig ssm \
        init-values deploy apply-eso uninstall deploy-all deploy-all-tf \
        init-app plan-app apply-app destroy-app

INFRA_DIR := infra
HELM_DIR  := helm
APP_DIR   := app

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

status: ## Check deployment state and show what to run next
	$(INFRA_DIR)/scripts/status.sh

status-quick: ## Quick status check (skip SSM and K8s queries)
	$(INFRA_DIR)/scripts/status.sh --quick

quickstart: ## Interactive setup wizard — generates terraform.tfvars
	$(INFRA_DIR)/scripts/quickstart.sh

# ── Pass 1: Infrastructure ────────────────────────────────────────────────────

setup-env: ## Set up secrets in SSM (prints the source command you need to run)
	@echo ""
	@if [ -n "$$TF_VAR_langsmith_api_key_salt" ]; then \
		echo "  \033[32m✔\033[0m  Environment already configured (TF_VAR_* vars are set)."; \
		echo "     To re-run: unset TF_VAR_langsmith_api_key_salt && source $(INFRA_DIR)/scripts/setup-env.sh"; \
	else \
		echo "  \033[1msetup-env.sh must be sourced so it can export variables into your shell.\033[0m"; \
		echo "  Make runs commands in a subshell, so it cannot do this for you."; \
		echo ""; \
		echo "  Copy and run:"; \
		echo ""; \
		echo "    \033[36msource $(INFRA_DIR)/scripts/setup-env.sh\033[0m"; \
	fi
	@echo ""

init: ## terraform init (infra)
	terraform -chdir=$(INFRA_DIR) init

plan: ## terraform plan (infra)
	terraform -chdir=$(INFRA_DIR) plan

apply: ## terraform apply (infra)
	terraform -chdir=$(INFRA_DIR) apply

preflight: ## Run infra preflight checks
	$(INFRA_DIR)/scripts/preflight.sh

kubeconfig: ## Update kubeconfig for the EKS cluster
	$(INFRA_DIR)/scripts/set-kubeconfig.sh

ssm: ## Interactive SSM parameter manager (or: ./infra/scripts/manage-ssm.sh <cmd>)
	$(INFRA_DIR)/scripts/manage-ssm.sh

# ── Pass 2: Helm Deployment (scripts) ────────────────────────────────────────

init-values: ## Generate Helm values from Terraform outputs
	$(HELM_DIR)/scripts/init-values.sh

deploy: ## Deploy LangSmith via Helm
	$(HELM_DIR)/scripts/deploy.sh

apply-eso: ## Re-apply ESO ClusterSecretStore + ExternalSecret (no Helm redeploy)
	$(HELM_DIR)/scripts/apply-eso.sh

uninstall: ## Uninstall LangSmith Helm release
	$(HELM_DIR)/scripts/uninstall.sh

# ── Pass 2: Terraform Helm (alternative) ─────────────────────────────────────

init-app: ## Pull infra outputs into app/infra.auto.tfvars.json
	$(APP_DIR)/scripts/pull-infra-outputs.sh

plan-app: init-app ## terraform plan (app) — auto-pulls infra outputs first
	terraform -chdir=$(APP_DIR) init -input=false
	terraform -chdir=$(APP_DIR) plan

apply-app: ## terraform apply (app)
	terraform -chdir=$(APP_DIR) apply

destroy-app: ## terraform destroy (app)
	terraform -chdir=$(APP_DIR) destroy

# ── Combo Targets ─────────────────────────────────────────────────────────────

deploy-all: apply init-values deploy ## Full deploy: infra apply → init-values → helm deploy

deploy-all-tf: apply init-app ## Full deploy via Terraform: infra apply → app init+apply
	terraform -chdir=$(APP_DIR) init -input=false
	terraform -chdir=$(APP_DIR) apply
