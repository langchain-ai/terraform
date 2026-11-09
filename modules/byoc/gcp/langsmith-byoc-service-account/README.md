# LangSmith BYOC - GCP Customer Service Account (Beta)

> **Beta:** GCP BYOC is in beta. This module's inputs, outputs, and granted roles may change between releases. Pin a release tag, and check the release notes before upgrading.

Provisions the service account in **your GCP project** that the LangSmith control plane impersonates to stand up and manage BYOC data planes in your project.

| Resource | Purpose |
|----------|---------|
| `var.service_account_id` (default `langsmith-byoc-provisioner`) | The identity the control plane provisions data planes as. |
| Custom roles `<prefix>Provisioner`, `<prefix>ProjectIamGranter`, `<prefix>ServiceAccountUser` | Exactly the permissions data plane provisioning and teardown use, bound to the service account. See [Permissions](#permissions). With `byo_iam`, only `<prefix>Provisioner`, with fewer permissions. |
| Data plane service accounts, their project roles, and the custom role `<prefix>ServiceAccountIamManager` | Only with `byo_iam`. See [Bring your own IAM](#bring-your-own-iam). |
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

By default, the provisioner holds three custom roles, not predefined admin roles:

- **`<prefix>Provisioner`**: the permissions for creating, updating and deleting data plane resources. These are the VPC, subnets, Cloud NAT, the Private Service Connect endpoint, GKE, Cloud SQL, Memorystore, Cloud Storage, Cloud DNS, Secret Manager, the Artifact Registry repository for in-cluster deployment builds and the data plane service accounts. It also has the list and get permissions that teardown needs to confirm deletions. The list comes from provisioning and tearing down data planes with nothing more.
- **`<prefix>ProjectIamGranter`**: reads and sets the project IAM policy. The binding has an IAM condition so the provisioner can only add or remove grants of the project roles the data planes use: `artifactregistry.reader`, `cloudsql.admin`, `cloudsql.client`, `cloudsql.instanceUser`, `container.admin`, `container.defaultNodeServiceAccount`, `redis.dbConnectionUser` and `secretmanager.secretAccessor`. Data plane workloads get narrower grants: External Secrets' `secretmanager.secretAccessor` has a condition limiting it to the data plane's own secrets, and cert-manager gets `dns.admin` on the data plane's DNS zones only (through the zones' IAM policies), never on the project.
- **`<prefix>ServiceAccountUser`**: `iam.serviceAccounts.actAs`, so GKE nodes and workloads can run as the data plane service accounts. IAM conditions are not evaluated for actAs, so this binding is unconditional.

With `byo_iam`, the permissions change. See [Bring your own IAM](#bring-your-own-iam). [Deployment observability](#deployment-observability) adds permissions when you turn it on.

### Use a project that holds only LangSmith resources

The project is the boundary of the provisioner's access, as the data plane resource group is on Azure. GCP IAM conditions cannot limit service account permissions by account name; they see only the account's numeric ID. So by default, the provisioner's service account permissions (`iam.serviceAccounts.setIamPolicy`, `actAs`) apply to every service account in the project. Through them, the provisioner could act as any of those accounts. Likewise, `artifactregistry.repositories.setIamPolicy` applies to every Artifact Registry repository in the project, and with [deployment observability](#deployment-observability), the log sink permissions apply to every log in the project. Keep other workloads, service accounts and repositories out of the project. [`byo_iam`](#bring-your-own-iam) takes the other service accounts out of the provisioner's reach, but its other permissions still apply to the whole project.

Custom role IDs are unique per project, so set `custom_role_id_prefix` when more than one copy of the module targets a project.

### Bring your own IAM

Set `byo_iam = true` to create the data plane service accounts and their project roles yourself. The provisioner then needs no service account admin and no project IAM writes.

> **CAUTION:** Set `byo_iam` before you create data planes in the project. Do not change it while data planes exist.

The module then creates these service accounts in the project. LangSmith finds them by these account IDs. All data planes in the project share them.

| Service account | Used by | Project roles |
|-----------------|---------|---------------|
| `langsmith-workload` | The LangSmith application | `roles/cloudsql.client`, `roles/cloudsql.instanceUser`, `roles/redis.dbConnectionUser` |
| `langsmith-external-secrets` | External Secrets Operator | `roles/secretmanager.secretAccessor`, with a condition limiting it to secrets whose IDs start with `ls-` |
| `langsmith-cert-manager` | cert-manager | None. LangSmith grants `roles/dns.admin` on each data plane's DNS zones. |
| `langsmith-postgres-setup` | The job that sets up the Cloud SQL databases | `roles/cloudsql.admin` |
| `langsmith-node` | GKE nodes | `roles/container.defaultNodeServiceAccount`, `roles/artifactregistry.reader` |
| `langsmith-sandbox-host` | Sandbox GKE nodes | `roles/container.defaultNodeServiceAccount`, `roles/artifactregistry.reader`, `roles/redis.dbConnectionUser` |

Name any secrets of your own in the project so their IDs don't start with `ls-`. Otherwise External Secrets can read them.

It also grants `roles/container.admin` on the project to `var.crossplane_service_account`. The LangSmith control plane reaches the data plane GKE clusters through it.

In-cluster deployment builds are not supported with `byo_iam`. They run as a build service account that the provisioner creates for each data plane.

With `deployment_observability`, the module also grants `langsmith-workload` `roles/monitoring.viewer` on the project and `roles/logging.viewAccessor` with a condition limiting it to log views whose names end in `-smith-logs/views/_AllLogs`, the views of the data planes' log buckets.

In this mode, the provisioner gets:

- **`<prefix>Provisioner`** without `iam.serviceAccounts.create`, `delete`, `update` and `setIamPolicy`. It keeps `get`, `list` and `getIamPolicy`.
- **`<prefix>ServiceAccountIamManager`**: `iam.serviceAccounts.getIamPolicy` and `iam.serviceAccounts.setIamPolicy`, bound on each of the six service accounts, not on the project.
- **`roles/iam.serviceAccountUser`**, bound on `langsmith-node` and `langsmith-sandbox-host` only. GKE node pools run as them.

The module does not create `<prefix>ProjectIamGranter` or `<prefix>ServiceAccountUser`. So the provisioner cannot create, update or delete service accounts and cannot change the project IAM policy. It can set IAM policies on these six accounts only, and act as `langsmith-node` and `langsmith-sandbox-host` only. It can still read the other service accounts in the project and their IAM policies.

LangSmith still creates the Workload Identity bindings on these accounts, the Token Creator grant of `langsmith-workload` on itself, and the `roles/dns.admin` grants for `langsmith-cert-manager` on the data plane DNS zones. The Workload Identity bindings need the project's workload identity pool, which exists only after LangSmith creates the first GKE cluster. That is why the provisioner can set the IAM policies of the six accounts. Through them, it can let an identity act as any of the six.

Create the data plane with `byoiam_enabled` set to `true`.

## Deployment observability

Set `deployment_observability = true` before LangSmith turns on deployment observability for a data plane in the project. LangSmith then shows Monitoring charts and searchable runtime and build log history for each LangGraph deployment, and reads them from this project:

- **Metrics:** the data plane's GKE cluster runs Managed Prometheus managed collection, which scrapes the LangGraph deployment pods. Managed Prometheus bills per sample ingested. CPU, memory and restart charts use GKE system metrics, which are free.
- **Logs:** LangSmith creates a log bucket for each data plane, `<data plane>-smith-logs`, in the data plane's region, and a sink that routes only the LangSmith namespace's container logs from the data plane's cluster to it. The bucket keeps them for 30 days unless LangSmith sets another retention; Cloud Logging bills retention past 30 days. The project's `_Default` bucket keeps its copy, so those logs are stored twice. The bucket is kept, with its logs, if observability is turned off.
- **Reads:** the LangSmith app's service account gets `roles/logging.viewAccessor` on its data plane's log bucket view only, so it reads no other logs in the project, and `roles/monitoring.viewer` on the project.

The setting makes these changes:

| | Added |
|---|---|
| APIs (with `enable_apis`) | `logging.googleapis.com`, `monitoring.googleapis.com` |
| `<prefix>Provisioner` | `logging.buckets.create`, `logging.buckets.get`, `logging.buckets.update`, `logging.sinks.create`, `logging.sinks.delete`, `logging.sinks.get`, `logging.sinks.update` |
| `<prefix>ProjectIamGranter` condition (without `byo_iam`) | `roles/logging.viewAccessor` and `roles/monitoring.viewer` join the roles the provisioner may grant. LangSmith grants `roles/logging.viewAccessor` with a condition naming the data plane's log view. Changing the condition replaces the binding. |
| `langsmith-workload` (with `byo_iam`) | `roles/monitoring.viewer` on the project, and `roles/logging.viewAccessor` with a condition limiting it to the data planes' log views |

Sinks do not support IAM conditions, so the sink permissions apply to every sink in the project: the provisioner could route any of the project's logs to another destination, or change or delete the project's other sinks (not `_Required`). Turn it on only in a project that holds only LangSmith resources.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `project_id` | The GCP project that hosts the LangSmith data planes. | required |
| `crossplane_service_account` | LangSmith control plane Crossplane service account that impersonates the provisioner. | required |
| `external_id` | External ID from **Settings > Data Planes** in LangSmith. Must not be empty and must be at most 256 characters. The module writes it as the description of the provisioner service account. | required |
| `service_account_id` | Account ID of the provisioner service account. | `langsmith-byoc-provisioner` |
| `enable_apis` | Enable the GCP APIs that data planes use. | `true` |
| `custom_role_id_prefix` | Prefix of the custom role IDs the module creates. | `langsmithByoc` |
| `byo_iam` | Create the data plane service accounts and their project roles. See [Bring your own IAM](#bring-your-own-iam). | `false` |
| `deployment_observability` | Let LangSmith turn on deployment observability. See [Deployment observability](#deployment-observability). | `false` |

## Outputs

| Name | Description |
|------|-------------|
| `provisioner_service_account` | Email of the provisioner service account. |
| `byo_iam_service_accounts` | Emails of the data plane service accounts, keyed by account ID. Empty unless `byo_iam` is `true`. |
