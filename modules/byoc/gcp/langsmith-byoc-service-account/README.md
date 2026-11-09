# LangSmith BYOC - GCP Customer Service Account (Beta)

> **Beta:** GCP BYOC is in beta. This module's inputs, outputs, and granted roles may change between releases. Pin a release tag, and check the release notes before upgrading.

Provisions the service account in **your GCP project** that the LangSmith control plane impersonates to stand up and manage BYOC data planes in your project.

| Resource | Purpose |
|----------|---------|
| `var.service_account_id` (default `langsmith-byoc-provisioner`) | The identity the control plane provisions data planes as. |
| Custom roles `<prefix>Provisioner`, `<prefix>ProjectIamGranter`, `<prefix>ServiceAccountUser` | Exactly the permissions data plane provisioning and teardown use, bound to the service account. See [Permissions](#permissions). With `byo_iam`, only `<prefix>Provisioner`, with fewer permissions. |
| Data plane service accounts, their project roles, and the custom role `<prefix>ServiceAccountIamManager` | Only with `byo_iam`. See [Bring your own IAM](#bring-your-own-iam). |
| Custom roles `<prefix>Named<kind>` (one per kind in the table under [Limit changes to data plane names](#limit-changes-to-data-plane-names)) | Only with `restrict_to_langsmith_names`. See [Limit changes to data plane names](#limit-changes-to-data-plane-names). |
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

With `byo_iam` or `restrict_to_langsmith_names`, the permissions change. See [Bring your own IAM](#bring-your-own-iam) and [Limit changes to data plane names](#limit-changes-to-data-plane-names).

### Use a project that holds only LangSmith resources

The project is the boundary of the provisioner's access, as the data plane resource group is on Azure. GCP IAM conditions cannot limit service account permissions by account name; they see only the account's numeric ID. So by default, the provisioner's service account permissions (`iam.serviceAccounts.setIamPolicy`, `actAs`) apply to every service account in the project. Through them, the provisioner could act as any of those accounts. Likewise, `artifactregistry.repositories.setIamPolicy` applies to every Artifact Registry repository in the project. Keep other workloads, service accounts and repositories out of the project. [`byo_iam`](#bring-your-own-iam) takes the other service accounts out of the provisioner's reach, but its other permissions still apply to the whole project.

Custom role IDs are unique per project, so set `custom_role_id_prefix` when more than one copy of the module targets a project.

### Limit changes to data plane names

If the project also holds resources that are not LangSmith's, set `restrict_to_langsmith_names = true` and [`byo_iam = true`](#bring-your-own-iam). The provisioner can then change and delete only the data plane's own resources of the kinds below, found by name. LangSmith names every data plane resource `langsmith-<hash>-<key>` and every data plane secret `ls-<data plane>-<key>`.

> **IMPORTANT:** Use `restrict_to_langsmith_names` together with `byo_iam`. Without `byo_iam`, the provisioner can grant the data plane roles on the project (`<prefix>ProjectIamGranter`). An IAM condition limits which roles it grants but not to whom, and those roles include `roles/container.admin`, `roles/cloudsql.admin` and `roles/secretmanager.secretAccessor` on the whole project. By granting one to itself, the provisioner could reach every GKE cluster, Cloud SQL instance or secret in the project, whatever its name. With `byo_iam`, the provisioner has no project IAM writes.

> **CAUTION:** Data planes created before LangSmith named resources `langsmith-` have other names. The provisioner can't update or delete their resources of these kinds, so they can't be upgraded or torn down. Set this only in a project whose data planes were all created with the `langsmith-` names, or recreate the older data planes first.

The permissions below move from `<prefix>Provisioner` to a role per kind. Each role is bound with an IAM condition on the resource name:

| Role | Permissions | Condition |
|------|-------------|-----------|
| `<prefix>NamedCloudSql` | `cloudsql.instances.create`, `delete`, `update` | `resource.name.extract("/instances/{name}").startsWith("langsmith-")` |
| `<prefix>NamedGke` | `container.clusters.create`, `delete`, `update` (node pool changes are checked against their cluster) | `resource.name.extract("/clusters/{name}").startsWith("langsmith-")` |
| `<prefix>NamedForwardingRules` | `compute.forwardingRules.create`, `delete`, `setLabels`, `pscDelete`, `pscSetLabels`, `pscUpdate` | `resource.name.extract("/forwardingRules/{name}").startsWith("langsmith-")` |
| `<prefix>NamedNetworks` | `compute.networks.delete`, `update`, `updatePolicy`, `addPeering`, `removePeering`, `updatePeering` | `resource.name.extract("/networks/{name}").startsWith("langsmith-")` |
| `<prefix>NamedSubnetworks` | `compute.subnetworks.delete`, `update`, `setPrivateIpGoogleAccess` | `resource.name.extract("/subnetworks/{name}").startsWith("langsmith-")` |
| `<prefix>NamedRouters` | `compute.routers.delete`, `update` (Cloud NAT is configured on the router) | `resource.name.extract("/routers/{name}").startsWith("langsmith-")` |
| `<prefix>NamedAddresses` | `compute.addresses.delete`, `deleteInternal`, `setLabels` | `resource.name.extract("/addresses/{name}").startsWith("langsmith-")` |
| `<prefix>NamedRedisClusters` | `redis.clusters.create`, `delete`, `update` | `resource.name.extract("/clusters/{name}").startsWith("langsmith-")` |
| `<prefix>NamedConnectionPolicies` | `networkconnectivity.serviceConnectionPolicies.delete`, `update` | `resource.name.extract("/serviceConnectionPolicies/{name}").startsWith("langsmith-")` |
| `<prefix>NamedStorage` | `storage.buckets.create`, `delete`, `update`, `setIamPolicy`; `storage.managedFolders.create`, `delete`, `setIamPolicy`; `storage.objects.delete` | `resource.name.startsWith("projects/_/buckets/langsmith-")` |
| `<prefix>NamedSecretManager` | `secretmanager.secrets.create`, `delete`; `secretmanager.versions.add` | `resource.name.extract("/secrets/{name}").startsWith("ls-")` |

Each kind was checked in a test project: a `langsmith-` name was allowed and any other name denied. The provisioner keeps the `get`, `list` and `use` permissions of these kinds. It also keeps unconditioned the creates that were not checked: networks, subnets, routers, addresses, global addresses (`compute.globalAddresses.*`, the private services access range), service connection policies and PSC forwarding rules (`pscCreate`). A new resource cannot change an existing one.

Name your own resources of these kinds so they don't start with `langsmith-`, and your own secrets so their IDs don't start with `ls-`.

The module grants no `createTagBinding` permission. A project-wide `createTagBinding` would let the provisioner tag a resource that is not LangSmith's and then change it under a tag condition. Compute Engine checks `createTagBinding` against the resource's numeric ID, so a name condition can't narrow it for networks, subnets, routers or addresses.

These kinds don't carry the resource name in their IAM checks, so a name condition can't narrow them. They stay unconditioned in `<prefix>Provisioner`, and the provisioner can still change or delete any resource of these kinds in the project:

- Artifact Registry repositories
- Cloud DNS managed zones and record sets
- Cloud SQL databases. They do follow a tag on their instance, but LangSmith doesn't tag its instances yet.
- Service Directory
- Private services access connections (`servicenetworking`) and global addresses
- Service accounts. Use [`byo_iam`](#bring-your-own-iam) to take them out of the provisioner's reach.

Use a dedicated project for a full boundary. As a partial measure, tag your own resources of the kinds above with a protected tag and add a condition such as `!resource.matchTag(...)` to the provisioner's bindings, or an IAM deny policy. Artifact Registry repositories and Cloud SQL instances can be tagged; Cloud DNS managed zones can't, so they stay unprotected. Do not put the tag on the project, because resources inherit project tags.

The setting needs no other provider than the module's Google provider `~> 6.0`.

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

In this mode, the provisioner gets:

- **`<prefix>Provisioner`** without `iam.serviceAccounts.create`, `delete`, `update` and `setIamPolicy`. It keeps `get`, `list` and `getIamPolicy`.
- **`<prefix>ServiceAccountIamManager`**: `iam.serviceAccounts.getIamPolicy` and `iam.serviceAccounts.setIamPolicy`, bound on each of the six service accounts, not on the project.
- **`roles/iam.serviceAccountUser`**, bound on `langsmith-node` and `langsmith-sandbox-host` only. GKE node pools run as them.

The module does not create `<prefix>ProjectIamGranter` or `<prefix>ServiceAccountUser`. So the provisioner cannot create, update or delete service accounts and cannot change the project IAM policy. It can set IAM policies on these six accounts only, and act as `langsmith-node` and `langsmith-sandbox-host` only. It can still read the other service accounts in the project and their IAM policies.

LangSmith still creates the Workload Identity bindings on these accounts, the Token Creator grant of `langsmith-workload` on itself, and the `roles/dns.admin` grants for `langsmith-cert-manager` on the data plane DNS zones. The Workload Identity bindings need the project's workload identity pool, which exists only after LangSmith creates the first GKE cluster. That is why the provisioner can set the IAM policies of the six accounts. Through them, it can let an identity act as any of the six.

Create the data plane with `byoiam_enabled` set to `true`.

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
| `restrict_to_langsmith_names` | Limit the provisioner's creates, changes and deletes of the kinds listed under Limit changes to data plane names to data plane names. Use with `byo_iam`. See [Limit changes to data plane names](#limit-changes-to-data-plane-names). | `false` |

## Outputs

| Name | Description |
|------|-------------|
| `provisioner_service_account` | Email of the provisioner service account. |
| `byo_iam_service_accounts` | Emails of the data plane service accounts, keyed by account ID. Empty unless `byo_iam` is `true`. |
