# LangSmith BYOC - GCP Customer Service Account (Beta)

> **Beta:** GCP BYOC is in beta. This module's inputs, outputs, and granted roles may change between releases. Pin a release tag, and check the release notes before upgrading.

Provisions the service account in **your GCP project** that the LangSmith control plane impersonates to stand up and manage BYOC data planes in your project.

| Resource | Purpose |
|----------|---------|
| `var.service_account_id` (default `langsmith-byoc-provisioner`) | The identity the control plane provisions data planes as. |
| Custom roles `<prefix>Provisioner`, `<prefix>ProjectIamGranter`, `<prefix>ServiceAccountUser` | Exactly the permissions data plane provisioning and teardown use, bound to the service account. See [Permissions](#permissions). |
| Token Creator on that service account | Lets `var.crossplane_service_account`, the LangSmith control plane, impersonate it. No other LangSmith identity is trusted. |
| Project APIs | Enables the APIs data planes use. Set `enable_apis = false` if you manage the project's APIs elsewhere. |

## Prerequisites

1. A GCP project for the LangSmith data plane, and credentials with permission to create service accounts, grant project IAM roles, and enable APIs in it.
2. Terraform `>= 1.11.0` and the Google provider `~> 6.0`.
3. The `crossplane_service_account` provided by LangChain.
4. The external ID from **Settings > Data Planes** in the LangSmith UI. Copy this value and use it as `external_id`. Do not make your own value.

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

variable "external_id" {
  description = "External ID from Settings > Data Planes in the LangSmith UI."
  type        = string
}

module "langsmith_byoc_service_account" {
  source = "github.com/langchain-ai/terraform//modules/byoc/gcp/langsmith-byoc-service-account?ref=<release tag>"

  project_id                 = "<your-project-id>"
  crossplane_service_account = "<provided by LangChain>"
  external_id                = var.external_id
}

output "provisioner_service_account" {
  value = module.langsmith_byoc_service_account.provisioner_service_account
}
```

Set `external_id` in the `terraform.tfvars` file of your root module to the value from **Settings > Data Planes**:

```hcl
external_id = "<external-id-copied-from-langsmith>"
```

Share the `provisioner_service_account` output with LangChain when you create a data plane.

### External ID

Every customer's provisioner trusts the same LangSmith Crossplane service account. So before LangSmith uses a provisioner, it checks that the description of the service account is the external ID of the LangSmith organization that creates the data plane. The module writes `external_id` as that description. This stops another LangSmith organization from using your provisioner.

## Permissions

The provisioner holds three custom roles, not predefined admin roles:

- **`<prefix>Provisioner`**: the permissions for creating, updating and deleting data plane resources. These are the VPC, subnets, Cloud NAT, the Private Service Connect endpoint, GKE, Cloud SQL, Memorystore, Cloud Storage, Cloud DNS, Secret Manager and the data plane service accounts. It also has the list and get permissions that teardown needs to confirm deletions. The list comes from provisioning and tearing down data planes with nothing more.
- **`<prefix>ProjectIamGranter`**: reads and sets the project IAM policy. The binding has an IAM condition so the provisioner can only add or remove grants of the project roles the data planes use: `artifactregistry.reader`, `cloudsql.admin`, `cloudsql.client`, `container.admin`, `container.defaultNodeServiceAccount`, `dns.admin`, `redis.dbConnectionUser` and `secretmanager.secretAccessor`.
- **`<prefix>ServiceAccountUser`**: `iam.serviceAccounts.actAs`, so GKE nodes and workloads can run as the data plane service accounts. IAM conditions are not evaluated for actAs, so this binding is unconditional.

### Use a project that holds only LangSmith resources

The project is the boundary of the provisioner's access, as the data plane resource group is on Azure. GCP IAM conditions cannot limit service account permissions by account name; they see only the account's numeric ID. So the provisioner's service account permissions (`iam.serviceAccounts.setIamPolicy`, `actAs`) apply to every service account in the project. Through them, the provisioner could act as any of those accounts. Keep other workloads and service accounts out of the project.

Custom role IDs are unique per project, so set `custom_role_id_prefix` when more than one copy of the module targets a project.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | The GCP project that hosts the LangSmith data planes. | required |
| `crossplane_service_account` | LangSmith control plane Crossplane service account that impersonates the provisioner. | required |
| `external_id` | External ID from **Settings > Data Planes** in LangSmith. Must not be empty and must be at most 256 characters. The module writes it as the description of the provisioner service account. | required |
| `service_account_id` | Account ID of the provisioner service account. | `langsmith-byoc-provisioner` |
| `enable_apis` | Enable the GCP APIs that data planes use. | `true` |
| `custom_role_id_prefix` | Prefix of the custom role IDs the module creates. | `langsmithByoc` |

## Outputs

| Name | Description |
|------|-------------|
| `provisioner_service_account` | Email of the provisioner service account. |
