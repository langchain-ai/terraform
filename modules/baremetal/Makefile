# LangSmith Bare-Metal Deployment — Task Runner
#
# Runs against an existing Kubernetes cluster (kubeadm, k3s, ...): there is no
# cloud foundation. Terraform builds the in-cluster backing services
# (Postgres x2, Redis, RustFS, platform add-ons); Helm installs LangSmith.
#
# Pass 1 (infra):       make init → make plan → make apply
# Secrets:              make setup-env   (infra/.secrets.env, chmod 600)
# Pass 2 (helm):        make init-values → make deploy
# Terraform flags:      make plan ARGS="-target=module.postgres_langsmith"   (see make help)

.PHONY: help setup-env init plan apply destroy tf init-values deploy

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
	@echo "    make init    ARGS=\"-upgrade\"                          # re-resolve provider versions"
	@echo "    make plan    ARGS=\"-target=module.postgres_langsmith\" # plan one module"
	@echo "    make plan    ARGS=\"-out=tfplan\"                       # save a plan file"
	@echo "    make apply   ARGS=\"tfplan\"                            # apply that saved plan"
	@echo "    make tf      ARGS=\"state list\"                        # any other terraform command"
	@echo ""

# ── Pass 1: Infrastructure ────────────────────────────────────────────────────

setup-env: ## Create or complete the app secrets in infra/.secrets.env (prompts for license + admin)
	$(INFRA_DIR)/scripts/setup-env.sh

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

# ── Pass 2: Helm ──────────────────────────────────────────────────────────────

init-values: ## Write helm/values/ from Terraform outputs (no secrets)
	$(HELM_DIR)/scripts/init-values.sh

deploy: ## Build langsmith-config from infra/.secrets.env, then helm upgrade --install LangSmith
	$(HELM_DIR)/scripts/deploy.sh
