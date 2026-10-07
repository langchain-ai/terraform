# LangSmith BYOC - GCP Customer Service Account (Beta)

> **Beta:** GCP BYOC is in beta. This module's inputs, outputs, and granted roles may change between releases. Pin a release tag, and check the release notes before upgrading.

Provisions the service account in **your GCP project** that the LangSmith control plane impersonates to stand up and manage BYOC data planes in your project.

| Resource | Purpose |
|----------|---------|
| `var.service_account_id` (default `langsmith-byoc-provisioner`) | Holds the project roles that data plane provisioning needs. |
| Token Creator on that service account | Lets `var.crossplane_service_account`, the LangSmith control plane, impersonate it. No other LangSmith identity is trusted. |
| Project APIs | Enables the APIs data planes use. Set `enable_apis = false` if you manage the project's APIs elsewhere. |

## Prerequisites

1. A GCP project for the LangSmith data plane, and credentials with permission to create service accounts, grant project IAM roles, and enable APIs in it.
2. Terraform `>= 1.11.0` and the Google provider `~> 6.0`.
3. The `crossplane_service_account` provided by LangChain.

## Usage

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

module "langsmith_byoc_service_account" {
  source = "github.com/langchain-ai/terraform//modules/byoc/gcp/langsmith-byoc-service-account?ref=<release tag>"

  project_id                 = "<your-project-id>"
  crossplane_service_account = "<provided by LangChain>"
}

output "provisioner_service_account" {
  value = module.langsmith_byoc_service_account.provisioner_service_account
}
```

Share the `provisioner_service_account` output with LangChain when you create a data plane.

## Permissions

The provisioner holds project-level admin roles for Cloud SQL, Compute, GKE, Cloud DNS, IAM, Private Service Connect, Memorystore, Secret Manager, Service Directory, service networking, and Cloud Storage. Deploy into a project dedicated to LangSmith.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | The GCP project that hosts the LangSmith data planes. | required |
| `crossplane_service_account` | LangSmith control plane Crossplane service account that impersonates the provisioner. | required |
| `service_account_id` | Account ID of the provisioner service account. | `langsmith-byoc-provisioner` |
| `enable_apis` | Enable the GCP APIs that data planes use. | `true` |

## Outputs

| Name | Description |
|------|-------------|
| `provisioner_service_account` | Email of the provisioner service account. |
