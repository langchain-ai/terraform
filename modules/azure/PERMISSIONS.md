# Azure permissions

The identity that runs `terraform apply` needs two kinds of access: permission to create resources, and permission to create role assignments. Contributor grants the first and not the second, so a Contributor-only identity builds most of the deployment and then fails partway through with a 403.

## Required roles

Grant one of these combinations to the deploying identity at subscription scope:

| Roles | Role definition ID | Covers |
|-------|-------------------|--------|
| `Owner` | `8e3af657-a8ff-443c-a75c-2fe8c4bcb635` | Everything, including role assignments |
| `Contributor` + `Role Based Access Control Administrator` | `b24988ac-6180-42a0-ab88-20f7382dd24c`, `f58310d9-a9f6-439a-9e8d-f62e7b41a168` | Preferred least-privilege pairing |
| `Contributor` + `User Access Administrator` | `b24988ac-6180-42a0-ab88-20f7382dd24c`, `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Equivalent, broader than the pairing above |

The deployment creates its own resource group by default, which requires subscription scope. To work with rights on one resource group only, have the group created for you and set `create_resource_group = false` and `existing_resource_group_name` in `terraform.tfvars` ([deploying into an existing resource group](README.md#deploying-into-an-existing-resource-group)). Grant the same roles on that group instead.

`Role Based Access Control Administrator` is the narrower of the two role-assignment roles. It grants `Microsoft.Authorization/roleAssignments/write` without the broader access-management rights that `User Access Administrator` carries.

## Run as a service principal

The deploying identity does not have to be your `az login` user. Two routes make it a service principal, and they are not interchangeable.

**`az login --service-principal`.** Prefer this one. Terraform and the CLI both authenticate as the principal, so the `make` targets that reach Key Vault through `az` (`setup-env`, `k8s-secrets`, `keyvault`) act as the same identity Terraform does.

```bash
az login --service-principal \
  --username "$APP_ID" \
  --password "$CLIENT_SECRET" \
  --tenant "$TENANT_ID"
az account set --subscription "$SUBSCRIPTION_ID"
```

**`ARM_*` environment variables.** The azurerm provider reads these before it falls back to the CLI, so they override whatever `az login` holds. This is the CI route, where the pipeline sets them from a secret store.

```bash
export ARM_CLIENT_ID="$APP_ID"
export ARM_CLIENT_SECRET="$CLIENT_SECRET"
export ARM_TENANT_ID="$TENANT_ID"
```

`ARM_SUBSCRIPTION_ID` is optional, because the provider takes the subscription from `subscription_id` in `terraform.tfvars`. Set it only to the same value: `make preflight` fails when it disagrees with the active `az` subscription, since every check the script runs would then describe a different subscription than the deployment.

Grant the principal the roles in the table above at subscription scope, the same as any other deploying identity. `make preflight` resolves whichever route is in effect and prints the object ID Terraform will present, so run it after switching. Resolving that object ID takes a directory read (`az ad sp show`); without one the preflight reports the identity but downgrades its RBAC verdict to a warning. The apply itself does not need the directory read.

### Key Vault needs both identities to be the same principal

Terraform grants `Key Vault Secrets Officer` on the vault to the identity the azurerm provider authenticates as, and that grant is what lets it write the application secrets. The Key Vault scripts are a separate path: they reach the same vault through `az`, as the `az login` identity.

Set `ARM_CLIENT_ID` while `az login` holds a user and those are two different principals. Terraform succeeds, the vault grant lands on the service principal, and `make setup-env` then fails with a 403 on the vault data plane. Either log in as the principal, or grant `Key Vault Secrets Officer` on the vault to the operator who runs the scripts as well.

## Verify access before the first apply

Run `make preflight` for the automated version of this check. It resolves the identity Terraform will authenticate as, confirms that identity can write role assignments, and reports PIM-eligible roles, ABAC conditions, and deny assignments. Use the manual probe below to inspect a specific action or a principal other than your own.

Checking for a role by name misses three cases: assignments inherited from a management group, ABAC conditions that restrict which roles you may grant, and deny assignments. The `checkAccess` API evaluates all three and returns the effective decision.

```bash
SUB=$(az account show --query id -o tsv)
OID=$(az ad signed-in-user show --query id -o tsv)

cat > /tmp/checkaccess.json <<JSON
{
  "subject": { "attributes": { "ObjectId": "$OID" } },
  "actions": [
    { "id": "Microsoft.Authorization/roleAssignments/write", "isDataAction": false },
    { "id": "Microsoft.KeyVault/vaults/write", "isDataAction": false },
    { "id": "Microsoft.ContainerService/managedClusters/write", "isDataAction": false },
    { "id": "Microsoft.DBforPostgreSQL/flexibleServers/write", "isDataAction": false },
    { "id": "Microsoft.ManagedIdentity/userAssignedIdentities/write", "isDataAction": false }
  ]
}
JSON

az rest --method post \
  --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Authorization/checkAccess?api-version=2018-09-01-preview" \
  --headers "Content-Type=application/json" \
  --body @/tmp/checkaccess.json \
  --query "[].{action:actionId, decision:accessDecision, condition:roleAssignment.condition, deny:denyAssignment}" \
  -o table
```

Every row must read `Allowed`. A populated `condition` or `deny` column means the grant is restricted even when the decision is `Allowed`, so read those columns rather than the decision alone.

For a service principal, replace the `az ad signed-in-user show` call with the principal's object ID. Note that `2018-09-01-preview` is the only api-version this endpoint supports.

## Role assignments created during deployment

The deployment creates the following assignments. Each one requires `Microsoft.Authorization/roleAssignments/write` at the listed scope.

| Role granted | Role definition ID | Scope | Grantee | Created when |
|--------------|-------------------|-------|---------|--------------|
| `Key Vault Secrets Officer` | `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` | Key Vault | The deploying identity | Always |
| `Key Vault Secrets User` | `4633458b-17de-408a-b874-0445c86b69e6` | Key Vault | Pod managed identity | Always |
| `Storage Blob Data Contributor` | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | Storage account | Pod managed identity | Always |
| `DNS Zone Contributor` | `befefa01-2a29-4197-83a8-272ff33ce314` | DNS zone | cert-manager identity | `cert_manager_principal_id` is set |
| `Reader` | `acdd72a7-3385-48ef-bd42-f606fba81ae7` | Resource group | AGIC identity | `ingress_controller = "agic"` |
| `Contributor` | `b24988ac-6180-42a0-ab88-20f7382dd24c` | Application Gateway | AGIC identity | `ingress_controller = "agic"` |
| `Network Contributor` | `4d97b98b-1d4f-4787-a291-c67834d212e7` | Virtual network | AGIC identity | `ingress_controller = "agic"` |
| `Virtual Machine Administrator Login` | `1c0163c0-47e6-4577-8991-ea5c82e286e4` | Bastion VM | Operators | Bastion module is enabled |
| `Network Contributor` | `4d97b98b-1d4f-4787-a291-c67834d212e7` | AKS subnet, or the virtual network with a zone ID in `aks_private_dns_zone_id` | AKS control-plane identity | `aks_control_plane_identity = "user"`, with grants managed |
| `Private DNS Zone Contributor` | `b12aa53e-6015-4669-85d0-8515ebb3ae7f` | API server private DNS zone | AKS control-plane identity | As above, with a zone ID in `aks_private_dns_zone_id` |

The Key Vault assignment to the deploying identity is self-granting: Terraform gives itself `Key Vault Secrets Officer` so that it can then write `postgres-admin-password` and `langsmith-license-key` through the Key Vault data plane. The vault runs in RBAC mode, so no access policy path exists as a fallback. Set `keyvault_manage_secrets = false` to drop both writes, and `keyvault_manage_terraform_admin_assignment = false` alongside it to drop the grant they exist for, as below.

## Control-plane identity grants

With `aks_control_plane_identity = "user"`, the AKS control plane runs as a user-assigned identity: `<cluster_name>-control-plane`, which Terraform creates in the deployment's resource group, or the one in `aks_control_plane_identity_id`. AKS uses its roles while it creates the cluster, so they must exist first:

| Role | Scope | Needed when |
|------|-------|-------------|
| `Network Contributor` | The AKS subnet | Always |
| `Network Contributor` | The subnet's route table | The subnet has one. Terraform does not make this grant |
| `Network Contributor` | The cluster's VNet | The API server is private and registers in a zone you supply that is not yet linked to the VNet, because AKS then links it |
| `Private DNS Zone Contributor` | The zone in `aks_private_dns_zone_id` | The API server is private and registers in a zone you supply |

Who makes the grants follows `aks_control_plane_identity_manage_grants`, which defaults to `create_vnet`:

- **`true`.** Terraform makes the grants, waits 300 seconds for Azure to apply them, then creates the cluster. With a zone you supply, it grants on the VNet in place of the subnet, whether or not the zone is linked already. The deploying identity needs `roleAssignments/write` at each scope. This is the default when Terraform built the VNet.
- **`false`.** Terraform makes no grants, and the network's owner makes them. This is the default on a supplied VNet. The identity must already exist and be set in `aks_control_plane_identity_id`. The plan reads its assignments and fails if a scope has none. The error names the principal ID and gives the `az role assignment create` command for each missing grant.

The check covers the subnet, its route table when it has one, and the zone. It does not check the VNet, which needs a grant only when the zone is not linked yet. It accepts any role at the scope or above it, so a custom role passes, and so does a grant on the VNet's resource group or subscription. A grant at management-group scope is reported missing, because a management group's path is not a prefix of the subscription's: grant at the subnet, the route table, and the zone as well. Azure decides whether the role carries enough permissions when it creates the cluster, and fails the create if it does not.

To deploy with `false`:

1. Create the identity, and give its principal ID to the network's owner:

   ```bash
   az identity create --resource-group <rg> --name <cluster_name>-control-plane --query principalId --output tsv
   ```

2. The network's owner grants the roles in the table above to that principal.
3. Set `aks_control_plane_identity_id` to the identity's resource ID, and run `make apply`. If AKS fails the create on the network's permissions, the grants have not taken effect yet: wait a few minutes and run `make apply` again.

## Deploy without Key Vault access

Two settings take Key Vault out of the deploying identity's requirements:

```hcl
keyvault_manage_terraform_admin_assignment = false  # skip the self-grant
keyvault_manage_secrets                    = false  # write no secrets
```

The first skips `Microsoft.Authorization/roleAssignments/write` on the vault, the second skips the data-plane writes that grant exists for. Apply then touches the vault's control plane only. `make seed-secrets` writes all nine secrets afterwards, under your own credentials rather than Terraform's, so it needs `Key Vault Secrets Officer` on the vault at that point and nothing earlier. Everything downstream is unchanged: `make k8s-secrets` still reads the vault to build `langsmith-config-secret`.

This does not remove the deployment's need for `roleAssignments/write` altogether. `Storage Blob Data Contributor` on the storage account is not optional, because LangSmith pods need it at runtime, and it has no toggle. A deployer who holds no role-assignment rights at all still fails there.

### Turning it off on a deployment that already applied

Leaving `keyvault_manage_secrets` at its default needs no migration. Setting it to false afterwards does, because Terraform reads `count = 0` as "delete these two secrets from the vault". Nothing breaks at the moment of the delete, since no runtime path reads the vault: the failure surfaces later, when `make k8s-secrets` cannot read `langsmith-license-key` to build `langsmith-config-secret`. Soft delete keeps both recoverable for the vault's retention window.

Drop them from state first, which leaves the vault untouched. Read the addresses out of state rather than typing them: `postgres_admin_password` is un-indexed on deployments that last applied before this flag existed and `[0]` after, while `langsmith_license_key` carried a `count` already and is `[0]` either way:

```bash
terraform -chdir=infra state list | grep azurerm_key_vault_secret
```

```bash
terraform -chdir=infra state rm '<address>'   # once per address listed
```

Then set the flag, and confirm `terraform plan` reports no change to the vault's secrets. `make seed-secrets` is write-once, so running it afterwards skips both and the vault keeps the values it already had.

On a deployment created with the flag on, the two addresses are `module.keyvault.azurerm_key_vault_secret.postgres_admin_password[0]` and `module.keyvault.azurerm_key_vault_secret.langsmith_license_key[0]`; on one from before the count, the first is un-indexed, which is why the list above is read rather than typed.

### Turning it on after seeding

The other direction needs a migration too. With `keyvault_manage_secrets = false`, `make seed-secrets` wrote `postgres-admin-password` and `langsmith-license-key` outside Terraform; setting the flag to true afterwards makes Terraform try to create both and fail with "already exists - to be managed via Terraform this resource needs to be imported". Import them first, by their versioned URIs:

```bash
KV=<vault name>
terraform -chdir=infra import 'module.keyvault.azurerm_key_vault_secret.postgres_admin_password[0]' \
  "$(az keyvault secret show --vault-name "$KV" --name postgres-admin-password --query id -o tsv)"
terraform -chdir=infra import 'module.keyvault.azurerm_key_vault_secret.langsmith_license_key[0]' \
  "$(az keyvault secret show --vault-name "$KV" --name langsmith-license-key --query id -o tsv)"
```

Then set the flag and confirm `terraform plan` shows both secrets unchanged. A `secrets.auto.tfvars` value that differs from the seeded one plans an update, which is the rotation you would expect from the flag.

## Private DNS zones you own

In a hub-and-spoke network the `privatelink` zones usually live in a central subscription and resource group, linked to the hub's DNS. Three inputs point the module at those zones instead of creating its own: `storage_private_dns_zone_id` (blob), `keyvault_private_dns_zone_id` (Key Vault), and `postgres_private_dns_zone_id` (PostgreSQL Flexible Server, for both LangSmith's server and the SmithDB metastore). With a zone supplied, Terraform creates no zone and no virtual network link. Linking the zone to the networks that must resolve these names stays with whoever owns it.

The module creates no role assignments for any of this. The zone's owner and the network's owner grant these to the identity that runs `terraform apply`, before the first apply:

| Grant | Scope | Role (or the one action, in a custom role) | Needed for |
|-------|-------|------------------------------------------|-----------|
| Join a supplied zone | The zone's resource group | `Private DNS Zone Contributor` (`b12aa53e-6015-4669-85d0-8515ebb3ae7f`), or `Microsoft.Network/privateDnsZones/join/action` | A private endpoint's DNS zone group (blob, Key Vault) adding its record to the zone. A Flexible Server created against a supplied zone registers its record there too; whether Azure checks the same action for it has not been tested, so grant it before the first apply either way. |
| Join the private-endpoint subnet | The subnet that holds the endpoints (`storage_private_endpoint_subnet_id`, `keyvault_private_endpoint_subnet_id`, or the AKS subnet when both are empty) | `Network Contributor` (`4d97b98b-1d4f-4787-a291-c67834d212e7`), or `Microsoft.Network/virtualNetworks/subnets/join/action` | Placing a private endpoint's network interface in a subnet the module did not create. |

Nothing in these paths calls `Microsoft.Authorization/roleAssignments/write`. The role assignments the module does make elsewhere are listed under [Role assignments created during deployment](#role-assignments-created-during-deployment). On the Key Vault path, the two that matter are the deployer's `Key Vault Secrets Officer` grant and the pods' `Key Vault Secrets User` grant; both can be turned off and made by the vault's owner instead ([Deploy without Key Vault access](#deploy-without-key-vault-access)).

- **Grant the zone join at the zone's resource group.** In testing, `join/action` granted at that scope worked.
- **Expect a delay before it takes effect.** In testing, it took between 12 and 40 minutes after the grant before the join succeeded. Until then, Azure fails the endpoint with `LinkedAuthorizationFailed`, even though `checkAccess` already reports the action as allowed. Wait and re-run `terraform apply`; the run is resumable.
- **A zone in another subscription.** That subscription must have the `Microsoft.DBforPostgreSQL` resource provider registered, or a Flexible Server that uses the zone does not finish creating (Microsoft Learn, "Network with private access (virtual network integration)", updated 2026-09-06).

### Key Vault with the private endpoint on

`keyvault_private_endpoint_enabled = true` turns the vault's public network access off. Every data-plane call then has to come from a network that resolves the vault's `privatelink.vaultcore` record:

- **`terraform plan` and `apply`.** Terraform reads and writes `postgres-admin-password` and `langsmith-license-key` in the vault on every run. Run them from a jump host or self-hosted runner in the VNet or a peered network. Alternatively, set `keyvault_manage_secrets = false`, so Terraform manages no secrets: the vault resource itself still plans from outside, because azurerm ignores its failed certificate-contacts read when public network access is off (`key_vault_resource.go`, v4.65.0 and v4.81.0).
- **`make seed-secrets` and `make k8s-secrets`.** Both read or write the vault, so they need the same network path.

The setting applies only to a vault the module creates (`create_keyvault = true`). A vault you supply keeps the network settings its owner gave it.

## Restrict which roles the deployer can assign

Security teams that will not grant unconditional role-assignment rights can attach an ABAC condition to `Role Based Access Control Administrator` that allows only the role definition IDs in the preceding table. Include every ID that applies to your configuration. A condition that omits one produces a partial deployment: assignments for the allowed roles succeed, and the first disallowed role returns 403 while earlier resources remain created.

## Resolve AuthorizationFailed on a role assignment

A failure that names `Microsoft.Authorization/roleAssignments/write` means the deploying identity cannot create role assignments at that scope:

```text
Error: unexpected status 403 (403 Forbidden) with error: AuthorizationFailed:
The client '<user>' with object id '<oid>' does not have authorization to
perform action 'Microsoft.Authorization/roleAssignments/write' over scope
'<scope>' or the scope is invalid.
```

Work through these causes in order:

1. **The identity holds Contributor only.** Add `Role Based Access Control Administrator` at subscription scope. This is the common case.
2. **A condition restricts which roles the identity may assign.** Suspect this when one assignment succeeds and another on the same scope fails, because the two differ only by role definition. Run the `checkAccess` probe and read the `condition` field.
3. **A deny assignment blocks the write.** Deny assignments override role assignments and appear in the `denyAssignment` field of the probe output. Azure Blueprints and managed application lock-downs both create them.
4. **The grant has not reached your session.** Role assignments take one to three minutes to take effect. If the grant arrived through a group, the token you are holding predates it and no wait fixes that: `checkAccess` reports `Allowed` while the apply still fails with 403. Sign in again (`az logout && az login`, or restart Cloud Shell) and re-run `terraform apply`.

After granting the missing role, re-run `terraform apply`. The run is resumable, and resources created before the failure stay in state.
