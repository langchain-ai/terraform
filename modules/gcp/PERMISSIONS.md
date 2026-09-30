# GCP permissions

The identity that runs `terraform apply` needs two kinds of access: permission to create resources, and permission to write IAM policy. `roles/editor` grants the first and not the second, so an Editor-only identity builds most of the deployment and then fails partway through with a 403 on the first IAM binding.

## Required roles

Grant one of these to the deploying identity on the project:

| Roles | Covers |
|-------|--------|
| `roles/owner` | Everything, including IAM policy writes |
| The predefined roles in the next table | Least-privilege set built from predefined roles |
| A custom role with the permissions under [Verify access before the first apply](#verify-access-before-the-first-apply) | Narrowest option |

The predefined set, and the configuration that needs each role:

| Role | Needed for | Required when |
|------|-----------|---------------|
| `roles/container.admin` | GKE cluster and node pools, and the Kubernetes objects Terraform creates in the cluster | Always |
| `roles/compute.networkAdmin` | VPC, subnet, Cloud Router, Cloud NAT, and the private service connection address | Always |
| `roles/compute.securityAdmin` | Firewall rules, and the Google-managed SSL certificate when `enable_dns_module = true` | Always |
| `roles/iam.serviceAccountAdmin` | Service accounts, and the Workload Identity bindings on them | Always |
| `roles/iam.serviceAccountUser` | Attaching a service account to GKE nodes | Always |
| `roles/resourcemanager.projectIamAdmin` | Project-level role grants to the service accounts Terraform creates | Always |
| `roles/serviceusage.serviceUsageAdmin` | Enabling the project's APIs | Always |
| `roles/storage.admin` | GCS buckets, and the bucket-level role grants | Always |
| `roles/cloudsql.admin` | Cloud SQL instances, databases, and users | `postgres_source = "external"` (the default), or SmithDB with `smithdb_metastore_source = "create"` |
| `roles/redis.admin` | Memorystore instance | `redis_source = "external"` (the default) |
| `roles/servicenetworking.networksAdmin` | VPC peering for Cloud SQL and Memorystore private IP | Cloud SQL or Memorystore is created, or `enable_sandboxes = true` |
| `roles/secretmanager.admin` | Secret Manager secret | `enable_secret_manager_module = true` |
| `roles/dns.admin` | Cloud DNS zone and records | `enable_dns_module = true` |
| `roles/cloudkms.admin` on the key | Granting the Cloud Storage service agent use of the key | `smithdb_bucket_kms_key` is set |

`roles/iam.serviceAccountUser` is needed even when `gke_node_service_account_email` is unset. GKE nodes then run as the Compute Engine default service account, and creating a node pool that runs as any service account requires `iam.serviceAccounts.actAs` on it. Grant the role on that one service account instead of the project to narrow it.

`roles/editor` plus `roles/iam.serviceAccountAdmin` plus `roles/resourcemanager.projectIamAdmin` also works, and is broader than the table.

## Authenticate

Terraform authenticates through Application Default Credentials. The Terraform run also shells out to `gcloud container clusters get-credentials`, and `make preflight` authenticates through the gcloud CLI, so log in both ways as the same identity:

```bash
gcloud auth login
gcloud config set project <your-project-id>
gcloud auth application-default login
```

To deploy as a service account, point ADC at it and activate it in gcloud:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
```

Grant the service account the roles in the preceding tables, the same as any other deploying identity. `make preflight` tests the gcloud identity, not the ADC one, so the two have to match for its result to describe the apply.

## Enable the bootstrap API

Terraform enables every API the deployment uses on the first apply. It cannot enable Cloud Resource Manager, because enabling the others goes through it. Enable it once before the first apply:

```bash
gcloud services enable cloudresourcemanager.googleapis.com --project <your-project-id>
```

Terraform enables the rest: `container`, `compute`, `sqladmin`, `redis`, `storage`, `servicenetworking`, `iam`, `secretmanager`, `certificatemanager`, `logging`, and `monitoring`. No variable turns this off, so the deployer needs `serviceusage.services.enable` even on a project where all of them are already on.

## Verify access before the first apply

Run `make preflight`. It reads `terraform.tfvars`, builds the permission list for your configuration, and tests it against the project with the Cloud Resource Manager `testIamPermissions` API. It also confirms billing is enabled on the project, and reports which APIs Terraform will enable. It exits 1 and lists the missing permissions when any are denied.

The script always tests:

```text
container.clusters.create
container.clusters.delete
compute.networks.create
compute.subnetworks.create
compute.routers.create
compute.firewalls.create
iam.serviceAccounts.create
iam.serviceAccounts.setIamPolicy
storage.buckets.create
resourcemanager.projects.getIamPolicy
resourcemanager.projects.setIamPolicy
serviceusage.services.enable
```

It adds these for the matching configuration:

| Configuration | Permissions added |
|---------------|------------------|
| `postgres_source = "external"` | `cloudsql.instances.create`, `cloudsql.databases.create` |
| `redis_source = "external"` | `redis.instances.create` |
| Cloud SQL or Memorystore is created, or `enable_sandboxes = true` | `servicenetworking.services.addPeering`, `compute.globalAddresses.create` |
| `enable_secret_manager_module = true` | `secretmanager.secrets.create` |
| `enable_dns_module = true` | `dns.managedZones.create`, `dns.resourceRecordSets.create` |
| `enable_dns_module = true`, unless `dns_create_certificate = false` | `compute.sslCertificates.create` |
| `enable_smithdb = true` with `smithdb_metastore_source = "create"` | `cloudsql.instances.create`, `cloudsql.databases.create` |
| `enable_smithdb = true` with `smithdb_metastore_use_auth_proxy = true` | `resourcemanager.projects.setIamPolicy` |

Pass flags through `ARGS`. `--domain <your-domain>` also checks for a Cloud DNS zone that covers the domain, and `--create-test-resources` creates and deletes a GCS bucket:

```bash
make preflight ARGS="--domain langsmith.example.com --create-test-resources"
```

The project-level test cannot see three things the apply also needs:

- **Bucket-level IAM** (`storage.buckets.setIamPolicy`). The test runs against the project, where this permission always reads as absent. `roles/storage.admin` grants it.
- **`iam.serviceAccounts.actAs`** on the node service account. `roles/iam.serviceAccountUser` grants it.
- **Organization Policy constraints and IAM deny policies.** These override grants, and `testIamPermissions` does not evaluate them. An apply that fails with `constraint violated` names the constraint; ask the organization's administrator about that constraint.

To test permissions for an identity other than your own, or a permission the script does not list, call the API directly:

```bash
curl -s -X POST \
  "https://cloudresourcemanager.googleapis.com/v1/projects/<your-project-id>:testIamPermissions" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"permissions": ["resourcemanager.projects.setIamPolicy", "iam.serviceAccounts.create"]}'
```

The response lists only the permissions the caller holds. Any permission in the request that is absent from the response is denied.

## IAM created during deployment

The deployment creates the following service accounts and grants. Project-level grants need `resourcemanager.projects.setIamPolicy`; bucket-level grants need `storage.buckets.setIamPolicy`; Workload Identity bindings need `iam.serviceAccounts.setIamPolicy` on the service account.

| Role granted | Scope | Grantee | Created when |
|--------------|-------|---------|--------------|
| `roles/storage.objectAdmin` | LangSmith bucket | `<name_prefix>-langsmith` service account | `enable_gcp_iam_module = true` (the default) |
| `roles/secretmanager.secretAccessor` | Project | `<name_prefix>-langsmith` service account | `enable_gcp_iam_module = true` |
| `roles/iam.workloadIdentityUser` | `<name_prefix>-langsmith` service account | Each LangSmith Kubernetes service account in `langsmith_namespace` | `enable_gcp_iam_module = true` |
| `roles/container.defaultNodeServiceAccount`, `roles/monitoring.metricWriter`, `roles/stackdriver.resourceMetadata.writer` | Project | Sandbox node service account | `enable_sandboxes = true` |
| `roles/storage.objectAdmin` | SmithDB bucket | SmithDB service account | `enable_smithdb = true` |
| `roles/iam.workloadIdentityUser` | SmithDB service account | The SmithDB Kubernetes service account | `enable_smithdb = true` |
| `roles/storage.objectViewer` | LangSmith bucket | SmithDB service account | `smithdb_migration_enabled = true` |
| `roles/cloudsql.client` | Project | SmithDB service account | `smithdb_metastore_use_auth_proxy = true` |
| `roles/cloudkms.cryptoKeyEncrypterDecrypter` | KMS key | Cloud Storage service agent | `smithdb_bucket_kms_key` is set |

`roles/secretmanager.secretAccessor` is granted whenever the IAM module is on, including when `enable_secret_manager_module = false`. The grant is project-wide, so the LangSmith service account can read every secret in the project.

## Deploy without creating IAM

Three variables reduce what the deployer has to create:

- `enable_gcp_iam_module = false` skips the LangSmith service account, its bucket and project grants, and every Workload Identity binding. Pods then have no GCS access through Workload Identity, so supply bucket credentials another way. This setting cannot be combined with `enable_sandboxes = true`.
- `smithdb_service_account_email` supplies an existing SmithDB service account. Terraform still creates that account's bucket, Workload Identity, and Cloud SQL grants.
- `gke_node_service_account_email` runs the nodes as an existing service account. Terraform never creates the main node service account; the deployer still needs `iam.serviceAccounts.actAs` on the one named here.

## Resolve a 403 during apply

A 403 that names `setIamPolicy` means the deploying identity cannot write IAM policy at that scope:

```text
Error: Error applying IAM policy for project "<project-id>": Error setting IAM
policy for project "<project-id>": googleapi: Error 403: Policy update access
denied., forbidden
```

Work through these causes in order:

1. **The identity holds `roles/editor` only.** Add `roles/resourcemanager.projectIamAdmin` and `roles/iam.serviceAccountAdmin`. This is the common case.
2. **An Organization Policy constraint blocks the grant.** `iam.allowedPolicyMemberDomains` rejects members outside the allowed domains, and `iam.disableServiceAccountCreation` blocks the service accounts. The error names the constraint.
3. **An IAM deny policy overrides the grant.** Deny policies take precedence over role grants, and neither `make preflight` nor `testIamPermissions` reports them. Ask the organization's administrator which deny policies apply to the project.
4. **The grant has not propagated.** IAM changes typically take effect within 2 minutes, and occasionally take 7 minutes or longer. Wait and re-run.

A 403 that reads `has not been used in project ... before or it is disabled` is an API, not a permission. Enable the bootstrap API as in [Enable the bootstrap API](#enable-the-bootstrap-api), then re-run.

After fixing the cause, re-run `terraform apply`. Resources created before the failure stay in state.
