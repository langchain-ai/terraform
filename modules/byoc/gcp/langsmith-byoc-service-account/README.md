# LangSmith BYOC - GCP Customer Service Account (Beta)

> **Beta:** GCP BYOC is in beta. This module's inputs, outputs, and granted roles may change between releases. Pin a release tag, and check the release notes before upgrading.

Provisions the service account in **your GCP project** that the LangSmith control plane impersonates to stand up and manage BYOC data planes in your project.

| Resource | Purpose |
|----------|---------|
| `var.service_account_id` (default `langsmith-byoc-provisioner`) | The identity the control plane provisions data planes as. |
| Custom roles `<prefix>Provisioner`, `<prefix>ProjectIamGranter`, `<prefix>ServiceAccountUser` | Exactly the permissions data plane provisioning and teardown use, bound to the service account. See [Permissions](#permissions). With `byo_iam`, only `<prefix>Provisioner`, with fewer permissions. |
| Data plane service accounts, their project roles, and the custom roles `<prefix>ServiceAccountIamManager` and `<prefix>PostgresSetup` | Only with `byo_iam`. See [Bring your own IAM](#bring-your-own-iam). |
| Custom roles `<prefix>Named<kind>` (one per kind in the table under [Limit changes to data plane names](#limit-changes-to-data-plane-names)) | The create, change and delete permissions of those kinds, bound with a condition on the resource name. See [Limit changes to data plane names](#limit-changes-to-data-plane-names). |
| Token Creator on that service account | Lets `var.crossplane_service_account`, the LangSmith control plane, impersonate it. No other LangSmith identity is trusted. |
| A cluster tag, `roles/container.admin` for `var.crossplane_service_account` on clusters with that tag, and the custom role `<prefix>ClusterConnect` | Lets the LangSmith control plane reach the data plane clusters, and no other cluster in the project. See [GKE access of the control plane](#gke-access-of-the-control-plane). |
| Project APIs | Enables the APIs data planes use. Set `enable_apis = false` if you manage the project's APIs elsewhere. |

## Prerequisites

1. A GCP project for the LangSmith data plane, and credentials with permission to create service accounts, grant project IAM roles, create tags (`roles/resourcemanager.tagAdmin`), and enable APIs in it.
2. Terraform `>= 1.11.0` and the Google provider 6, 7 or 8 (`>= 6.0, < 9.0`).
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

By default, the provisioner holds custom roles, not predefined admin roles:

- **`<prefix>Provisioner`**: the permissions for creating, updating and deleting data plane resources. These are the VPC, subnets, routes, Cloud NAT, the optional egress firewall policy, the Private Service Connect endpoint, GKE, Cloud SQL, Memorystore, Cloud Storage, Cloud DNS, Secret Manager, the Artifact Registry repository for in-cluster deployment builds and the data plane service accounts. It also has the list and get permissions that teardown needs to confirm deletions. The list comes from provisioning and tearing down data planes with nothing more. The create, change and delete permissions of the kinds that IAM checks by name are in the `<prefix>Named<kind>` roles instead.
- **`<prefix>ProjectIamGranter`**: reads and sets the project IAM policy. The binding has an IAM condition so the provisioner can only add or remove grants of the project roles the data planes use: `artifactregistry.reader`, `cloudsql.admin`, `cloudsql.client`, `cloudsql.instanceUser`, `container.defaultNodeServiceAccount`, `redis.dbConnectionUser` and `secretmanager.secretAccessor`. Data plane workloads get narrower grants: External Secrets' `secretmanager.secretAccessor` has a condition limiting it to the data plane's own secrets, and cert-manager gets `dns.admin` on the data plane's DNS zones only (through the zones' IAM policies), never on the project.
- **`<prefix>ServiceAccountUser`**: `iam.serviceAccounts.actAs`, so GKE nodes and workloads can run as the data plane service accounts. IAM checks on a service account carry only its numeric unique ID, and the provisioner creates these accounts, so no condition can single them out and this binding is unconditional.
- **`<prefix>Named<kind>`**: one role per kind of data plane resource, bound with a condition on the resource name. See [Limit changes to data plane names](#limit-changes-to-data-plane-names).

The module also grants `roles/container.admin` to `var.crossplane_service_account` on the GKE clusters that carry the module's cluster tag. The LangSmith control plane reaches the data plane clusters through it. The module makes this grant, not the provisioner, so the provisioner can't grant `roles/container.admin`. See [GKE access of the control plane](#gke-access-of-the-control-plane).

With `byo_iam`, the permissions change. See [Bring your own IAM](#bring-your-own-iam). [Deployment observability](#deployment-observability) adds permissions when you turn it on.

### Use a project that holds only LangSmith resources

The project is the boundary of the provisioner's access, as the data plane resource group is on Azure. GCP IAM conditions cannot limit service account permissions by account name: IAM checks a service account as `projects/-/serviceAccounts/<numeric unique ID>`, whether the request names it by email or by ID. So by default, the provisioner's service account permissions (`iam.serviceAccounts.setIamPolicy`, `actAs`) apply to every service account in the project. Through them, the provisioner could act as any of those accounts. Likewise, `artifactregistry.repositories.setIamPolicy` applies to every Artifact Registry repository in the project, and with [deployment observability](#deployment-observability), the log sink permissions apply to every log in the project. The project IAM granter's condition limits only which roles the provisioner grants, not to whom or with what condition, so the provisioner could grant itself `secretmanager.secretAccessor` on every secret in the project, and with deployment observability, `logging.viewAccessor` on every log. Keep other workloads, service accounts and repositories out of the project. [`byo_iam`](#bring-your-own-iam) takes the other service accounts out of the provisioner's reach, but its other permissions still apply to the whole project.

Apply one copy of this module per project: it creates the project's `managed_by` tag key, which can exist only once. Custom role IDs are unique per project, so set `custom_role_id_prefix` if the project already has roles with the default IDs.

### Limit changes to data plane names

The provisioner can create, change and delete only the data plane's own resources of the kinds below, found by name. Without `byo_iam`, it can still get around the Cloud SQL and Secret Manager limits by granting itself project roles; see [What names can't limit](#what-names-cant-limit). LangSmith names every data plane resource `langsmith-<hash>-<key>` and every data plane secret `ls-<data plane>-<key>`. With `byo_iam`, the project roles of the data plane service accounts are limited by name too. See [With `byo_iam`](#with-byo_iam).

> **CAUTION:** Data planes created before LangSmith named resources `langsmith-` have other names. The provisioner can't update or delete their resources of these kinds, so they can't be upgraded or torn down. Use this module version only in a project whose data planes were all created with the `langsmith-` names, or recreate the older data planes first.

The permissions below are in a role per kind, not in `<prefix>Provisioner`. Each role is bound with an IAM condition on the resource name:

| Role | Permissions | Condition |
|------|-------------|-----------|
| `<prefix>NamedCloudSql` | `cloudsql.instances.create`, `delete`, `update`, `createTagBinding`, `deleteTagBinding` | `resource.name.extract("/instances/{name}").startsWith("langsmith-")` |
| `<prefix>NamedGke` | `container.clusters.create`, `delete`, `update`, `createTagBinding`, `deleteTagBinding` (node pool changes are checked against their cluster) | `resource.name.extract("/clusters/{name}").startsWith("langsmith-")` |
| `<prefix>NamedForwardingRules` | `compute.forwardingRules.create`, `delete`, `setLabels`, `pscCreate`, `pscDelete`, `pscSetLabels`, `pscUpdate` | `resource.name.extract("/forwardingRules/{name}").startsWith("langsmith-")` |
| `<prefix>NamedNetworks` | `compute.networks.create`, `delete`, `update`, `updatePolicy`, `use`, `addPeering`, `removePeering`, `updatePeering`, `setFirewallPolicy` | `resource.name.extract("/networks/{name}").startsWith("langsmith-")` |
| `<prefix>NamedSubnetworks` | `compute.subnetworks.create`, `delete`, `update`, `use`, `setPrivateIpGoogleAccess` | `resource.name.extract("/subnetworks/{name}").startsWith("langsmith-")` |
| `<prefix>NamedRoutes` | `compute.routes.create`, `delete` (routes that keep Google API traffic on private.googleapis.com) | `resource.name.extract("/routes/{name}").startsWith("langsmith-")` |
| `<prefix>NamedFirewallPolicies` | `compute.firewallPolicies.create`, `delete`, `update`, `use` (the optional deny-by-default egress firewall: a global network firewall policy and its rules, attached to the data plane VPC) | `resource.name.extract("/firewallPolicies/{name}").startsWith("langsmith-")` |
| `<prefix>NamedRouters` | `compute.routers.create`, `delete`, `update` (Cloud NAT is configured on the router) | `resource.name.extract("/routers/{name}").startsWith("langsmith-")` |
| `<prefix>NamedAddresses` | `compute.addresses.create`, `createInternal`, `delete`, `deleteInternal`, `setLabels`, `use`, `useInternal`; `compute.globalAddresses.create`, `createInternal`, `delete`, `deleteInternal`, `setLabels` (the private services access range) | `resource.name.extract("/addresses/{name}").startsWith("langsmith-")` |
| `<prefix>NamedRedisClusters` | `redis.clusters.create`, `delete`, `update` | `resource.name.extract("/clusters/{name}").startsWith("langsmith-")` |
| `<prefix>NamedConnectionPolicies` | `networkconnectivity.serviceConnectionPolicies.create`, `delete`, `update` | `resource.name.extract("/serviceConnectionPolicies/{name}").startsWith("langsmith-")` |
| `<prefix>NamedStorage` | `storage.buckets.create`, `delete`, `update`, `setIamPolicy`; `storage.managedFolders.create`, `delete`, `setIamPolicy`; `storage.objects.delete` | `resource.name.startsWith("projects/_/buckets/langsmith-")` |
| `<prefix>NamedSecretManager` | `secretmanager.secrets.create`, `delete`; `secretmanager.versions.add` | `resource.name.extract("/secrets/{name}").startsWith("ls-")` |

Each permission was checked in a test project: a `langsmith-` name was allowed and any other name denied. The firewall policy fence has not been checked that way yet. Resources inside a network are fenced by the network too. Creating a subnet, a route or a Cloud Router checks `compute.networks.updatePolicy` on its network, and reserving a global address (the private services access range) checks `compute.networks.use`. So the provisioner can't add subnets, routes, routers, Cloud NAT or ranges to a network that isn't LangSmith's. The `use` permissions are checked against the subnet, address or network that a new resource refers to.

The provisioner keeps the `get` and `list` permissions of these kinds, and `compute.routers.use` and `compute.globalAddresses.use`, unconditioned.

Name your own resources of these kinds so they don't start with `langsmith-`, and your own secrets so their IDs don't start with `ls-`.

The only `createTagBinding` permissions the module grants are on `langsmith-` GKE clusters and Cloud SQL instances, for the `managed_by: langsmith` tag. A project-wide `createTagBinding` would let the provisioner tag a resource that is not LangSmith's and then change it under a tag condition. Compute Engine checks `createTagBinding` against the resource's numeric ID, so a name condition can't narrow it for networks, subnets, routers or addresses.

#### With `byo_iam`

The provisioner can set the IAM policies of the six data plane service accounts, so it can act as any of them. So with `byo_iam`, the module also limits these grants by name:

| Grant | Change |
|-------|--------|
| `langsmith-workload`: `roles/cloudsql.client`, `roles/cloudsql.instanceUser` | Limited to `langsmith-` Cloud SQL instances (`cloudsql.instances.get`, `connect` and IAM database `login`). |
| `langsmith-workload`, `langsmith-sandbox-host`: `roles/redis.dbConnectionUser` | Limited to `langsmith-` Memorystore for Redis clusters. |
| `langsmith-postgres-setup` | Instead of `roles/cloudsql.admin`, which the data plane compositions grant without `byo_iam` (also only on tagged instances): `<prefix>PostgresSetup` (`cloudsql.users.create`, `list`, `update`) on instances with the `managed_by: langsmith` tag, and `roles/cloudsql.viewer` limited to `langsmith-` instances. IAM checks of Cloud SQL users carry no instance name, but they match the instance's tags. LangSmith binds the tag to each data plane instance, and the provisioner can bind it only to `langsmith-` instances. |

`langsmith-external-secrets` reads only secrets whose IDs start with `ls-`.

#### GKE access of the control plane

The LangSmith control plane installs LangSmith into each data plane cluster through the cluster's DNS-based endpoint, as `var.crossplane_service_account`. GKE authorizes Kubernetes API requests through IAM with an empty resource name, so a condition on the cluster name can't limit them. A condition on a tag of the cluster does:

- The module creates the tag `managed_by: langsmith` in the project, and lets the provisioner use that value (`roles/resourcemanager.tagUser` on it). The project must not already have a `managed_by` tag key, and holds one copy of the module.
- LangSmith binds the tag to each data plane cluster it creates. The provisioner can bind it only to `langsmith-` clusters (`<prefix>NamedGke`), and can't tag the project, whose tags every cluster would inherit.
- `roles/container.admin` for `var.crossplane_service_account` has the condition `resource.matchTagId(<key>, <value>)`. It covers the GKE API and the Kubernetes API, through both the DNS-based and the IP-based endpoints, on tagged clusters only.
- The DNS-based endpoint checks `container.clusters.connect` without the cluster's tags, so `<prefix>ClusterConnect` grants that permission alone, limited to `langsmith-` cluster names. Connecting gives no access inside a cluster.

Don't put this tag on your own clusters or Cloud SQL instances, or on the project. Each was checked in a test project: the Kubernetes API of an untagged cluster answered 403 through both endpoints.

#### What names can't limit

These IAM checks carry no resource name, or a name LangSmith doesn't choose, so a name condition can't narrow them. In a project shared with your own resources, LangSmith's identities can still do the following:

- **Project role grants.** Without `byo_iam`, the provisioner grants the data plane service accounts their project roles (`<prefix>ProjectIamGranter`). An IAM condition limits which roles it can grant, but not to whom, and the grants are project-wide. So the provisioner can grant itself `roles/cloudsql.admin` or `roles/secretmanager.secretAccessor`, which gets around the Cloud SQL and `ls-` secret limits above. Use [`byo_iam`](#bring-your-own-iam) in a project that holds resources that aren't LangSmith's.
- **Artifact Registry.** The provisioner can change or delete any repository and set its IAM policy. `langsmith-node` and `langsmith-sandbox-host` can read every repository (`roles/artifactregistry.reader`).
- **Cloud DNS** managed zones and record sets.
- **Service Directory.** Namespace and service creates carry the name, but service deletes don't.
- **Private services access** (`servicenetworking`). The provisioner can't reserve a range in a network that isn't LangSmith's, but it can create a private services access connection in any network that already has a reserved range, and delete any network's connection.
- **Service connection policies in other networks.** Creating a policy checks no permission on its network, so the provisioner can create a `langsmith-` policy in any network in the project. Creating a Memorystore for Redis cluster also checks nothing on its network, so a `langsmith-` cluster can then get endpoints in that network.
- **Service accounts.** IAM checks carry the numeric ID, not the account name. With `byo_iam`, the provisioner can still read the other service accounts in the project and their IAM policies, but not change them.
- `roles/container.defaultNodeServiceAccount` of the node service accounts, which writes logs and metrics for the project.

Use a dedicated project for a full boundary. As a partial measure, tag your own resources of the kinds above with a protected tag and add a condition such as `!resource.matchTag(...)` to the provisioner's bindings, or an IAM deny policy. Artifact Registry repositories and Cloud SQL instances can be tagged; Cloud DNS managed zones can't, so they stay unprotected. Do not put the tag on the project, because resources inherit project tags.

### Bring your own IAM

Set `byo_iam = true` to create the data plane service accounts and their project roles yourself. The provisioner then needs no service account admin and no project IAM writes.

> **CAUTION:** Set `byo_iam` before you create data planes in the project. Do not change it while data planes exist.

The module then creates these service accounts in the project. LangSmith finds them by these account IDs. All data planes in the project share them.

| Service account | Used by | Project roles |
|-----------------|---------|---------------|
| `langsmith-workload` | The LangSmith application | `roles/cloudsql.client`, `roles/cloudsql.instanceUser`, `roles/redis.dbConnectionUser`; with [dedicated deployments](#dedicated-deployments), `roles/cloudsql.admin` limited to `lg-` instances |
| `langsmith-external-secrets` | External Secrets Operator | `roles/secretmanager.secretAccessor`, with a condition limiting it to secrets whose IDs start with `ls-` |
| `langsmith-cert-manager` | cert-manager | None. LangSmith grants `roles/dns.admin` on each data plane's DNS zones. |
| `langsmith-postgres-setup` | The job that sets up the Cloud SQL databases | `<prefix>PostgresSetup` (`cloudsql.users.create`, `list`, `update`) on instances with the `managed_by: langsmith` tag, and `roles/cloudsql.viewer` limited to `langsmith-` instances |
| `langsmith-node` | GKE nodes | `roles/container.defaultNodeServiceAccount`, `roles/artifactregistry.reader` |
| `langsmith-sandbox-host` | Sandbox GKE nodes | `roles/container.defaultNodeServiceAccount`, `roles/artifactregistry.reader`, `roles/redis.dbConnectionUser` |

Name any secrets of your own in the project so their IDs don't start with `ls-`. Otherwise External Secrets can read them.

The Cloud SQL and Redis grants above are limited to `langsmith-` resources by name. See [With `byo_iam`](#with-byo_iam).

In-cluster deployment builds are not supported with `byo_iam`. They run as a build service account that the provisioner creates for each data plane.

Deployment observability is not supported with `byo_iam` either. LangSmith would read logs and metrics as `langsmith-workload` before it could confirm that account's grants.

In this mode, the provisioner gets:

- **`<prefix>Provisioner`** without `iam.serviceAccounts.create`, `delete`, `update` and `setIamPolicy`. It keeps `get`, `list` and `getIamPolicy`.
- **`<prefix>ServiceAccountIamManager`**: `iam.serviceAccounts.getIamPolicy` and `iam.serviceAccounts.setIamPolicy`, bound on each of the six service accounts, not on the project.
- **`roles/iam.serviceAccountUser`**, bound on `langsmith-node` and `langsmith-sandbox-host` only. GKE node pools run as them.

The module does not create `<prefix>ProjectIamGranter` or `<prefix>ServiceAccountUser`. So the provisioner cannot create, update or delete service accounts and cannot change the project IAM policy. It can set IAM policies on these six accounts only, and act as `langsmith-node` and `langsmith-sandbox-host` only. It can still read the other service accounts in the project and their IAM policies.

LangSmith still creates the Workload Identity bindings on these accounts, the Token Creator grant of `langsmith-workload` on itself, and the `roles/dns.admin` grants for `langsmith-cert-manager` on the data plane DNS zones. The Workload Identity bindings need the project's workload identity pool, which exists only after LangSmith creates the first GKE cluster. That is why the provisioner can set the IAM policies of the six accounts. Through them, it can let an identity, itself included, act as any of the six and use their project roles. Those roles are limited by name, except as listed under [What names can't limit](#what-names-cant-limit).

Create the data plane with `byoiam_enabled` set to `true`.

## Deployment observability

Set `deployment_observability = true` before LangSmith turns on deployment observability for a data plane in the project. It is not supported with `byo_iam`. LangSmith then shows Monitoring charts and searchable runtime and build log history for each LangGraph deployment, and reads them from this project:

- **Metrics:** the data plane's GKE cluster runs Managed Prometheus managed collection, which scrapes the LangGraph deployment pods. Managed Prometheus bills per sample ingested. CPU, memory and restart charts use GKE system metrics, which are free.
- **Logs:** LangSmith creates a log bucket for each data plane, `langsmith-<hash>-logs`, in the data plane's region, and a sink that routes only the LangGraph deployment and build container logs from the data plane's cluster to it. The bucket keeps them for 30 days unless LangSmith sets another retention; Cloud Logging bills retention past 30 days. The project's `_Default` bucket keeps its copy, so those logs are stored twice. The bucket is kept, with its logs, if observability is turned off.
- **Reads:** the LangSmith app's service account gets `roles/logging.viewAccessor` on its data plane's log bucket view only, so it reads no other logs in the project, and `roles/monitoring.viewer` on the project.

Before you set it back to `false` or remove it, have LangSmith turn observability off or delete the data plane, for every data plane in the project, because the provisioner needs these permissions to remove the sinks and the read grants.

The setting makes these changes:

| | Added |
|---|---|
| APIs (with `enable_apis`) | `logging.googleapis.com`, `monitoring.googleapis.com` |
| `<prefix>Provisioner` | `logging.buckets.create`, `logging.buckets.get`, `logging.buckets.update`, `logging.sinks.create`, `logging.sinks.delete`, `logging.sinks.get`, `logging.sinks.update` |
| `<prefix>ProjectIamGranter` condition | `roles/logging.viewAccessor` and `roles/monitoring.viewer` join the roles the provisioner may grant. LangSmith grants `roles/logging.viewAccessor` with a condition naming the data plane's log view. Changing the condition replaces the binding. |

Sinks do not support IAM conditions, so the sink permissions apply to every sink in the project: the provisioner could route any of the project's logs to another destination, or change or delete the project's other sinks (not `_Required`). Likewise, the project IAM granter's condition limits only which role is granted, so the provisioner could grant itself `roles/logging.viewAccessor` with no condition and read every log view in the project, including the `_Required` bucket's audit logs, as it already can grant itself `roles/secretmanager.secretAccessor` on every secret. LangSmith grants the role only to the data plane's app service account, with a condition naming its log view. Turn it on only in a project that holds only LangSmith resources.

## Dedicated deployments

Set `dedicated_deployments = true` before LangSmith turns on dedicated deployments for a data plane in the project. Each dedicated LangGraph deployment then gets its own Cloud SQL instance, `lg-<id>`, which the LangSmith app creates, resizes and deletes in the data plane's region, with a private IP on the data plane's VPC through the private services access LangSmith already sets up.

The LangSmith app's service account needs `roles/cloudsql.admin` on those instances, limited to `lg-` names by the condition `resource.name.extract("/instances/{name}").startsWith("lg-")`, so it can't change the data planes' own `langsmith-` instances or yours:

- With `byo_iam`, the module grants it to `langsmith-workload`.
- Without `byo_iam`, LangSmith grants it to the data plane's app service account, and the setting changes nothing: the project IAM granter already allows `roles/cloudsql.admin`.

Name your own Cloud SQL instances so they don't start with `lg-`. Before you set it back to `false`, have LangSmith delete the dedicated deployments, because their instances can't be deleted without the grant.

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
| `deployment_observability` | Let LangSmith turn on deployment observability. Not with `byo_iam`. See [Deployment observability](#deployment-observability). | `false` |
| `dedicated_deployments` | Let LangSmith run dedicated deployments. Only changes anything with `byo_iam`. See [Dedicated deployments](#dedicated-deployments). | `false` |

## Outputs

| Name | Description |
|------|-------------|
| `provisioner_service_account` | Email of the provisioner service account. |
| `byo_iam_service_accounts` | Emails of the data plane service accounts, keyed by account ID. Empty unless `byo_iam` is `true`. |
