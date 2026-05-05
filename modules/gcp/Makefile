# LangSmith GCP Deployment — Task Runner
#
# First time?           make quickstart
# Pass 1 (infra):       make setup-env → make init → make plan → make apply
# Pass 2a (helm):       make init-values → make deploy
# Pass 2b (terraform):  make init-values → make init-app → make apply-app
# Full deploy:          make deploy-all
# Where am I?           make status

.PHONY: help quickstart status status-quick setup-env secrets init plan apply destroy \
        preflight kubeconfig \
        init-values deploy uninstall deploy-all \
        patch-lgp \
        init-app plan-app apply-app destroy-app

INFRA_DIR := infra
HELM_DIR  := helm
APP_DIR   := app

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

status: ## Check deployment state and show what to run next
	$(INFRA_DIR)/scripts/status.sh

status-quick: ## Quick status check (skip Secret Manager and K8s queries)
	$(INFRA_DIR)/scripts/status.sh --quick

quickstart: ## Interactive setup wizard — generates terraform.tfvars
	$(INFRA_DIR)/scripts/quickstart.sh

# ── Pass 1: Infrastructure ────────────────────────────────────────────────────

setup-env: ## Set up secrets in Secret Manager (prints the source command to run)
	@echo ""
	@if [ -n "$$TF_VAR_postgres_password" ]; then \
		echo "  \033[32m✔\033[0m  Environment already configured (TF_VAR_* vars are set)."; \
		echo "     To re-run: unset TF_VAR_postgres_password && source $(INFRA_DIR)/scripts/setup-env.sh"; \
	else \
		echo "  \033[1msetup-env.sh must be sourced so it can export variables into your shell.\033[0m"; \
		echo "  Make runs commands in a subshell, so it cannot do this for you."; \
		echo ""; \
		echo "  Copy and run:"; \
		echo ""; \
		echo "    \033[36msource $(INFRA_DIR)/scripts/setup-env.sh\033[0m"; \
	fi
	@echo ""

secrets: ## Interactive Secret Manager tool (list/get/set/validate/delete)
	$(INFRA_DIR)/scripts/manage-secrets.sh

init: ## terraform init (infra)
	terraform -chdir=$(INFRA_DIR) init

plan: ## terraform plan (infra)
	terraform -chdir=$(INFRA_DIR) plan

apply: ## terraform apply (infra)
	terraform -chdir=$(INFRA_DIR) apply

destroy: ## terraform destroy (infra)
	terraform -chdir=$(INFRA_DIR) destroy

preflight: ## Run GCP infra preflight checks
	$(INFRA_DIR)/scripts/preflight.sh

kubeconfig: ## Fetch kubeconfig for the GKE cluster
	$(HELM_DIR)/scripts/get-kubeconfig.sh

# ── Pass 2: Helm Deployment ───────────────────────────────────────────────────

init-values: ## Generate Helm values from Terraform outputs
	$(HELM_DIR)/scripts/init-values.sh

deploy: ## Deploy LangSmith via Helm
	$(HELM_DIR)/scripts/deploy.sh

uninstall: ## Uninstall LangSmith Helm release
	$(HELM_DIR)/scripts/uninstall.sh

# ── Pass 3: LGP Resource Patching ─────────────────────────────────────────────

patch-lgp: ## Patch LGP CRs for minimum/dev profiles (right-sizes redis sidecars + database)
	$(HELM_DIR)/scripts/patch-lgp-resources.sh

# ── Pass 2b: Terraform-native Helm deployment (alternative to scripts) ────────

init-app: ## Pull infra outputs into app/infra.auto.tfvars.json, then terraform init
	$(APP_DIR)/scripts/pull-infra-outputs.sh
	terraform -chdir=$(APP_DIR) init

plan-app: ## terraform plan (app — Helm deployment)
	terraform -chdir=$(APP_DIR) plan

apply-app: ## terraform apply (app — deploys LangSmith via Helm)
	terraform -chdir=$(APP_DIR) apply

destroy-app: ## terraform destroy (app — removes Helm release)
	terraform -chdir=$(APP_DIR) destroy

# ── Combo Targets ─────────────────────────────────────────────────────────────

deploy-all: apply init-values deploy ## Full deploy: infra apply → init-values → helm deploy
