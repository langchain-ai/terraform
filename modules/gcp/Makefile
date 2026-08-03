# LangSmith GCP Deployment — Task Runner
#
# First time?           make quickstart
# Pass 1 (infra):       make setup-env → make init → make plan → make apply
# Pass 2 (helm):        make init-values → make deploy
# Full deploy:          make deploy-all
# Where am I?           make status
# Terraform flags:      make plan ARGS="-target=module.gke_cluster"   (see make help)

.PHONY: help quickstart status status-quick setup-env secrets init plan apply destroy tf \
        preflight kubeconfig \
        init-values deploy uninstall deploy-all \
        patch-lgp

INFRA_DIR := infra
HELM_DIR  := helm

help: ## Show available targets
	@echo ""
	@echo "  \033[1mUsage:\033[0m make <target> [ARGS=\"<extra terraform flags>\"]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  \033[1mARGS is appended to the terraform command:\033[0m"
	@echo "    make init    ARGS=\"-upgrade\"                     # re-resolve provider versions"
	@echo "    make plan    ARGS=\"-target=module.gke_cluster\"   # plan one module"
	@echo "    make plan    ARGS=\"-out=tfplan\"                  # save a plan file"
	@echo "    make apply   ARGS=\"tfplan\"                       # apply that saved plan"
	@echo "    make apply   ARGS=\"-auto-approve\"                # skip the approval prompt"
	@echo "    make destroy ARGS=\"-target=module.redis\"         # destroy one module"
	@echo ""
	@echo "  \033[1mAny other terraform command — no need to remember -chdir:\033[0m"
	@echo "    make tf      ARGS=\"output\"                       # all infra outputs"
	@echo "    make tf      ARGS=\"output -raw storage_bucket_name\""
	@echo "    make tf      ARGS=\"state list\"                   # inspect infra state"
	@echo ""

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
	terraform -chdir=$(INFRA_DIR) init $(ARGS)

plan: ## terraform plan (infra)
	terraform -chdir=$(INFRA_DIR) plan $(ARGS)

apply: ## terraform apply (infra)
	terraform -chdir=$(INFRA_DIR) apply $(ARGS)

destroy: ## terraform destroy (infra)
	terraform -chdir=$(INFRA_DIR) destroy $(ARGS)

tf: ## Any terraform command in infra/ (make tf ARGS="state list")
	terraform -chdir=$(INFRA_DIR) $(ARGS)

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

# ── Combo Targets ─────────────────────────────────────────────────────────────

deploy-all: apply init-values deploy ## Full deploy: infra apply → init-values → helm deploy
