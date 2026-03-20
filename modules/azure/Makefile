# ──────────────────────────────────────────────────────────────────────────────
# LangSmith Azure — Makefile
# Wrapper for common Terraform + Helm operations. Mirrors the AWS Makefile.
#
# Usage:
#   make init          # initialise providers + backend
#   make plan          # preview changes
#   make apply         # apply infrastructure (Pass 1)
#   make kubeconfig    # fetch AKS credentials
#   make deploy        # helm deploy LangSmith (Pass 2)
#   make status        # show pod / ingress status
#   make destroy       # tear down all infrastructure
#
# Prerequisites: az CLI logged in, terraform installed, helm installed
# ──────────────────────────────────────────────────────────────────────────────

SHELL     := /bin/bash
INFRA_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))/infra

.PHONY: init plan apply kubeconfig deploy status destroy preflight help

help:
	@echo ""
	@echo "  LangSmith Azure — available targets"
	@echo ""
	@echo "  make init          initialise Terraform providers and backend"
	@echo "  make preflight     validate Azure login, provider registrations, and RBAC"
	@echo "  make plan          preview infrastructure changes"
	@echo "  make apply         apply Pass 1 infrastructure (AKS, Postgres, Redis, Blob, KV)"
	@echo "  make kubeconfig    fetch AKS credentials into ~/.kube/config"
	@echo "  make deploy        deploy LangSmith via Helm (Pass 2)"
	@echo "  make status        show pod, service, and ingress status in the langsmith namespace"
	@echo "  make destroy       destroy all infrastructure"
	@echo ""

init:
	cd $(INFRA_DIR) && terraform init

preflight:
	bash $(INFRA_DIR)/scripts/preflight.sh

plan:
	cd $(INFRA_DIR) && source setup-env.sh && terraform plan

apply:
	cd $(INFRA_DIR) && source setup-env.sh && terraform apply

kubeconfig:
	@CLUSTER=$$(cd $(INFRA_DIR) && terraform output -raw aks_cluster_name 2>/dev/null || echo ""); \
	RG=$$(cd $(INFRA_DIR) && terraform output -raw resource_group_name 2>/dev/null || echo ""); \
	if [ -z "$$CLUSTER" ] || [ -z "$$RG" ]; then \
	  echo "Error: run 'make apply' first to create the cluster"; exit 1; \
	fi; \
	az aks get-credentials --name "$$CLUSTER" --resource-group "$$RG" --overwrite-existing
	@echo "kubeconfig updated — current context: $$(kubectl config current-context)"

deploy:
	bash $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))/helm/scripts/deploy.sh

status:
	@echo "=== Pods ==="
	@kubectl get pods -n langsmith 2>/dev/null || echo "  (namespace not found — run 'make apply' then 'make deploy')"
	@echo ""
	@echo "=== Services ==="
	@kubectl get svc -n langsmith 2>/dev/null || true
	@echo ""
	@echo "=== Ingress ==="
	@kubectl get ingress -n langsmith 2>/dev/null || true
	@echo ""
	@echo "=== Certificates ==="
	@kubectl get certificate -n langsmith 2>/dev/null || true
	@echo ""
	@echo "=== KEDA ScaledObjects ==="
	@kubectl get scaledobject -n langsmith 2>/dev/null || true

destroy:
	cd $(INFRA_DIR) && source setup-env.sh && terraform destroy
