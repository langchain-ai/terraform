#!/bin/bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail

# --- Bastion bootstrap ---
# Installs the tools needed to run LangSmith Pass 1 and Pass 2 from the bastion.

LOG=/var/log/bastion-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Bastion bootstrap started at $(date -u) ==="

# System updates
dnf update -y -q

# --- kubectl ---
curl -fsSLo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# --- Helm ---
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- Terraform ---
dnf install -y -q dnf-plugins-core
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y -q terraform

# --- git (for cloning the deployment repo) ---
dnf install -y -q git

# --- jq (useful for parsing Terraform outputs) ---
dnf install -y -q jq

# --- Pre-configure kubeconfig for the EKS cluster ---
su - ec2-user -c "aws eks update-kubeconfig --name '${cluster_name}' --region '${region}'"

# --- Set default region for AWS CLI ---
su - ec2-user -c "aws configure set default.region '${region}'"

echo "=== Bastion bootstrap completed at $(date -u) ==="
echo "Tools installed: kubectl, helm, terraform, git, jq"
echo "Kubeconfig: pre-configured for cluster '${cluster_name}' in '${region}'"
