# LangSmith on GCP — Teardown Guide

> Check the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) before destroying for any notes on data migration or export.

This guide walks through a clean teardown — from removing the application layer down to destroying all GCP infrastructure.

---

## Overview

Teardown happens in reverse order of deployment:

```
Pass 3 (if enabled) — Remove LangGraph deployments (LGP CRDs + pods)
Pass 2              — Uninstall LangSmith Helm release
Pass 1              — Destroy all GCP infrastructure (terraform destroy)
```

---

## Step 1 — Remove LangGraph Platform Deployments (if enabled)

If Pass 3 (LangSmith Deployments) was enabled, remove LGP resources before uninstalling Helm:

```bash
# List all LangGraph deployments
kubectl get lgp -n langsmith

# Delete all LangGraph deployments
kubectl delete lgp --all -n langsmith

# Wait for operator to clean up pods
kubectl get pods -n langsmith -w

# Delete the LGP CRD
kubectl delete crd lgps.apps.langchain.ai
```

---

## Step 2 — Uninstall LangSmith Helm Release

```bash
# Uninstall the Helm release
helm uninstall langsmith -n langsmith

# Verify all pods are removed
kubectl get pods -n langsmith

# Delete the namespace (removes remaining ConfigMaps, Secrets, PVCs)
kubectl delete namespace langsmith
```

---

## Step 3 — Remove Kubernetes Bootstrap Resources

```bash
# Uninstall KEDA
helm uninstall keda -n keda
kubectl delete namespace keda

# Uninstall cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager

# Uninstall Envoy Gateway
helm uninstall envoy-gateway -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system
```

---

## Step 4 — Destroy GCP Infrastructure

Run from the `gcp/infra/langsmith` directory:

```bash
cd gcp/infra/langsmith

# Preview what will be destroyed
terraform plan -destroy

# Destroy all resources
terraform destroy
```

Terraform will destroy in dependency order:
- LangSmith Helm resources
- GKE cluster
- Cloud SQL instance
- Memorystore Redis
- GCS bucket
- VPC and networking

> **Data warning:** `terraform destroy` permanently deletes the Cloud SQL database and GCS bucket contents. Export any data you need to retain before proceeding.

---

## Step 5 — Manual Cleanup (if needed)

Some resources may require manual removal if Terraform state is out of sync:

```bash
# Delete GKE cluster
gcloud container clusters delete <cluster-name> --region <region>

# Delete Cloud SQL instance
gcloud sql instances delete <instance-name>

# Delete Memorystore Redis
gcloud redis instances delete <instance-name> --region <region>

# Delete GCS bucket
gsutil rm -r gs://<bucket-name>

# Delete VPC (after all dependent resources are removed)
gcloud compute networks delete <vpc-name>
```

---

## Step 6 — Verify Cleanup

```bash
# No GKE clusters remaining
gcloud container clusters list

# No Cloud SQL instances remaining
gcloud sql instances list

# No Memorystore instances remaining
gcloud redis instances list --region <region>

# No GCS bucket remaining
gsutil ls gs://<bucket-name> 2>&1 || echo "Bucket deleted"

# No VPC remaining
gcloud compute networks list --filter="name:<vpc-name>"
```
