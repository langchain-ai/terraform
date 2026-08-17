# Azure permissions

The identity that runs `terraform apply` needs two kinds of access: permission to create resources, and permission to create role assignments. Contributor grants the first and not the second, so a Contributor-only identity builds most of the deployment and then fails partway through with a 403.

## Required roles

Grant one of these combinations to the deploying identity at subscription scope:

| Roles | Role definition ID | Covers |
|-------|-------------------|--------|
| `Owner` | `8e3af657-a8ff-443c-a75c-2fe8c4bcb635` | Everything, including role assignments |
| `Contributor` + `Role Based Access Control Administrator` | `b24988ac-6180-42a0-ab88-20f7382dd24c`, `f58310d9-a9f6-439a-9e8d-f62e7b41a168` | Preferred least-privilege pairing |
| `Contributor` + `User Access Administrator` | `b24988ac-6180-42a0-ab88-20f7382dd24c`, `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Equivalent, broader than the pairing above |

Resource group scope is enough only if the resource group already exists and you set it in `terraform.tfvars`. The deployment creates its own resource group by default, which requires subscription scope.

`Role Based Access Control Administrator` is the narrower of the two role-assignment roles. It grants `Microsoft.Authorization/roleAssignments/write` without the broader access-management rights that `User Access Administrator` carries.

### Deletion protection needs Owner or UAA

`aks_deletion_protection` and `postgres_deletion_protection` place Azure management locks, which need `Microsoft.Authorization/locks/write`. That permission is the one place the least-privilege pairing above falls short:

| Role | `locks/write` | Why |
|------|--------------|-----|
| `Owner` | yes | `*` |
| `User Access Administrator` | yes | `Microsoft.Authorization/*` |
| `Role Based Access Control Administrator` | **no** | grants `roleAssignments/write` and `roleAssignments/delete` only |
| `Contributor` | **no** | NotActions denies `Microsoft.Authorization/*/Write` |

So `Contributor` + `Role Based Access Control Administrator` can build every resource in this deployment except these locks. Both variables default to `false`, so that pairing works out of the box. If you set either to `true` — `terraform.tfvars.production` does — deploy as `Owner` or `Contributor` + `User Access Administrator`, or the apply fails when it reaches the lock.

`make preflight` reads both flags from `terraform.tfvars` and checks `locks/write` only when one of them is on, so this failure surfaces before the apply rather than partway through it.

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

The Key Vault assignment to the deploying identity is self-granting: Terraform gives itself `Key Vault Secrets Officer` so that it can then write the application secrets through the Key Vault data plane. The vault runs in RBAC mode, so no access policy path exists as a fallback.

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
4. **The grant has not propagated.** Role assignments take one to three minutes to take effect. If access was granted in the last few minutes, run `az account get-access-token --query expiresOn` to confirm the token predates the grant, then re-authenticate with `az login`.

After granting the missing role, re-run `terraform apply`. The run is resumable, and resources created before the failure stay in state.
