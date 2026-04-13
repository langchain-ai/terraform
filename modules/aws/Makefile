# LangSmith AWS Deployment — Task Runner
#
# First time?        make quickstart
# Pass 1 (infra):    make setup-env → make init → make plan → make apply
# Pass 2 (tls):      make tls   (BYO ACM cert + Route53 A alias — when langsmith_domain is set)
# Pass 2 (helm):     make init-values → make deploy
# Pass 2 (tf):       make init-app → make plan-app → make apply-app
# Secrets:           make secrets   (check SSM status + TF_VAR_* export guidance)
# Fast deploy:       make quickdeploy   (chains apply → kubeconfig → init-values → deploy)
# Post-infra check:  make preflight-post
# Full deploy:       make deploy-all
# Teardown:          make uninstall → make destroy → make clean
# Where am I?        make status

.PHONY: help quickstart status status-quick setup-env init plan apply destroy \
        preflight preflight-post preflight-ssm kubeconfig ssm secrets secrets-list tls \
        init-values deploy apply-eso uninstall clean deploy-all deploy-all-tf \
        init-app plan-app apply-app destroy-app \
        test-e2e test-permutations test-parallel \
        quickdeploy quickdeploy-auto

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

destroy: ## terraform destroy (infra) — run make uninstall first
	terraform -chdir=$(INFRA_DIR) destroy

preflight: ## Run infra preflight checks
	$(INFRA_DIR)/scripts/preflight.sh

preflight-post: kubeconfig ## Post-infra preflight: kubectl + SSM params + helm values
	$(INFRA_DIR)/scripts/preflight.sh --post-infra

preflight-ssm: ## Check SSM params are populated (run after make setup-env)
	$(INFRA_DIR)/scripts/preflight.sh --ssm-only

kubeconfig: ## Update kubeconfig for the EKS cluster (must be sourced — prints the command)
	@echo ""
	@if [ -n "$$KUBECONFIG" ] && echo "$$KUBECONFIG" | grep -q "langsmith"; then \
		echo "  \033[32m✔\033[0m  KUBECONFIG already set: $$KUBECONFIG"; \
		echo "     To re-run: unset KUBECONFIG && source $(INFRA_DIR)/scripts/set-kubeconfig.sh"; \
	else \
		echo "  \033[1mset-kubeconfig.sh must be sourced so it can export KUBECONFIG into your shell.\033[0m"; \
		echo "  Make runs commands in a subshell, so it cannot do this for you."; \
		echo ""; \
		echo "  Copy and run:"; \
		echo ""; \
		echo "    \033[36msource $(INFRA_DIR)/scripts/set-kubeconfig.sh\033[0m"; \
	fi
	@echo ""

ssm: ## Interactive SSM parameter manager (or: ./infra/scripts/manage-ssm.sh <cmd>)
	$(INFRA_DIR)/scripts/manage-ssm.sh

secrets: ## Show SSM secrets status and export guidance (source setup-env.sh to populate)
	$(INFRA_DIR)/scripts/secrets-status.sh

secrets-list: ## List all SSM parameters for this deployment
	$(INFRA_DIR)/scripts/manage-ssm.sh list

tls: ## BYO ACM cert + Route53 A alias (requires langsmith_domain in tfvars, run after make apply)
	$(HELM_DIR)/scripts/tls.sh

# ── Pass 2: Helm Deployment (scripts) ────────────────────────────────────────

init-values: kubeconfig ## Generate Helm values from Terraform outputs
	$(HELM_DIR)/scripts/init-values.sh

deploy: ## Deploy LangSmith via Helm
	$(HELM_DIR)/scripts/deploy.sh

apply-eso: ## Re-apply ESO ClusterSecretStore + ExternalSecret (no Helm redeploy)
	$(HELM_DIR)/scripts/apply-eso.sh

uninstall: ## Uninstall LangSmith Helm release
	$(HELM_DIR)/scripts/uninstall.sh

clean: ## Remove all local generated/sensitive files (run after terraform destroy)
	$(INFRA_DIR)/scripts/clean.sh

test-e2e: ## Run E2E gateway tests (ALB or Envoy Gateway)
	$(HELM_DIR)/scripts/test-e2e.sh

test-permutations: ## Run permutation tests sequentially on current cluster (ARGS="1 2 5" for subset)
	$(INFRA_DIR)/scripts/test-permutations.sh $(ARGS)

test-parallel: ## Run permutation tests in parallel across isolated clusters — your cluster untouched
	$(INFRA_DIR)/scripts/test-orchestrator.sh $(ARGS)

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

deploy-all: apply kubeconfig init-values deploy ## Full deploy: infra apply → kubeconfig → init-values → helm deploy

deploy-all-tf: apply init-values init-app ## Full deploy via Terraform: infra apply → init-values → app init+apply
	terraform -chdir=$(APP_DIR) init -input=false
	terraform -chdir=$(APP_DIR) apply

quickdeploy: ## Full deploy in one command (must have run: source setup-env.sh + make quickstart)
	$(INFRA_DIR)/scripts/quickdeploy.sh

quickdeploy-auto: ## Full deploy non-interactive (auto-approve terraform)
	$(INFRA_DIR)/scripts/quickdeploy.sh --yes
