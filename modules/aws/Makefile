# LangSmith AWS Deployment — Task Runner
#
# Pass 1 (infra):  make init → make plan → make apply
# Pass 2 (helm):   make init-overrides → make deploy
# Pass 2 (tf):     make init-app → make plan-app → make apply-app
# Full deploy:     make deploy-all
#
# Note: `make setup` cannot source setup-env.sh into your shell.
#       Run `source infra/setup-env.sh` directly instead.

.PHONY: help status setup init plan apply preflight kubeconfig ssm \
        init-overrides deploy uninstall deploy-all \
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

# ── Pass 1: Infrastructure ────────────────────────────────────────────────────

setup: ## Remind how to source setup-env.sh (must be sourced, not run via Make)
	@echo ""
	@echo "  Cannot run setup-env.sh via Make — it must export vars into your shell."
	@echo ""
	@echo "  Run directly:"
	@echo "    source $(INFRA_DIR)/setup-env.sh"
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

init-overrides: ## Generate helm values-overrides.yaml from Terraform outputs
	$(HELM_DIR)/scripts/init-overrides.sh

deploy: ## Deploy LangSmith via Helm
	$(HELM_DIR)/scripts/deploy.sh

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

deploy-all: apply init-overrides deploy ## Full deploy: infra apply → init-overrides → helm deploy
