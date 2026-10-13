#!/bin/bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# shellcheck disable=SC2154  # tools_s3_uri/cluster_name/region are templatefile() variables
set -euo pipefail

# --- Bastion bootstrap without internet egress ---
# Copies kubectl, helm, and terraform from S3 instead of downloading them, so
# the S3 gateway endpoint and the SSM and EKS interface endpoints are enough.

LOG=/var/log/bastion-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Bastion bootstrap (no internet egress) started at $(date -u) ==="

for tool in kubectl helm terraform; do
  aws s3 cp --region "${region}" "${tools_s3_uri}/$tool" "/usr/local/bin/$tool"
  chmod +x "/usr/local/bin/$tool"
done

# git and jq come from the Amazon Linux repositories, which AWS serves from S3.
# An S3 gateway endpoint policy that blocks those buckets skips both.
dnf install -y -q git jq || echo "WARNING: could not reach the Amazon Linux repositories; git and jq are not installed"

# --- Pre-configure kubeconfig for the EKS cluster ---
su - ec2-user -c "aws eks update-kubeconfig --name '${cluster_name}' --region '${region}'"

# --- Set default region for AWS CLI ---
su - ec2-user -c "aws configure set default.region '${region}'"

echo "=== Bastion bootstrap completed at $(date -u) ==="
echo "Tools installed: kubectl, helm, terraform from ${tools_s3_uri}"
echo "Kubeconfig: pre-configured for cluster '${cluster_name}' in '${region}'"
