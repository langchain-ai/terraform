.PHONY: help init plan apply destroy preflight kubeconfig deploy

INFRA_DIR := infra
HELM_DIR  := helm

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Pass 1: Infrastructure
init: ## terraform init (infra)
	terraform -chdir=$(INFRA_DIR) init

plan: ## terraform plan (infra)
	terraform -chdir=$(INFRA_DIR) plan -var-file=terraform.tfvars

apply: ## terraform apply (infra)
	terraform -chdir=$(INFRA_DIR) apply -var-file=terraform.tfvars

destroy: ## terraform destroy (infra)
	terraform -chdir=$(INFRA_DIR) destroy -var-file=terraform.tfvars

preflight: ## Run GCP infra preflight checks
	$(INFRA_DIR)/scripts/preflight.sh

kubeconfig: ## Fetch kubeconfig from terraform outputs
	$(HELM_DIR)/scripts/get-kubeconfig.sh

# Pass 2: Helm
deploy: ## Deploy LangSmith via Helm
	$(HELM_DIR)/scripts/deploy.sh
