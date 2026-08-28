"""Exercise preflight.sh's RBAC and Postgres capability checks with a stubbed az CLI.

The checks worth testing are the ones you cannot produce on demand in a real
subscription: a deny assignment that overrides Owner, a PIM role held but not
activated, an ABAC-conditioned grant, a preview API that changes shape or stops
answering, and a Postgres capability response that is empty or malformed. Each
case builds an infra directory, copies the real script into it so INFRA_DIR
resolves inside the fixture, runs it with a stub `az` first on PATH, and asserts
on substrings of the rendered output.

Usage: python3 test-preflight-rbac.py
"""

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ANSI = re.compile(r"\x1b\[[0-9;]*m")

HERE = pathlib.Path(__file__).resolve().parent
STUB_DIR = HERE / "test-support"
SOURCE_SCRIPT = HERE / "preflight.sh"
WORKDIR = pathlib.Path(tempfile.mkdtemp(prefix="preflight-rbac-"))

SUB = "11111111-1111-1111-1111-111111111111"
SUB_SCOPE = f"/subscriptions/{SUB}"
RG_SCOPE = f"{SUB_SCOPE}/resourceGroups/langsmith-rg-dev"
VNET_ID = f"{SUB_SCOPE}/resourceGroups/platform-network-rg/providers/Microsoft.Network/virtualNetworks/hub-vnet"
USER_OID = "33333333-3333-3333-3333-333333333333"
SP_OID = "44444444-4444-4444-4444-444444444444"

OWNER_GUID = "8e3af657a8ff443ca75c2fe8c4bcb635"
CONTRIB_GUID = "b24988ac618042a0ab8820f7382dd24c"
CUSTOM_GUID = "aaaaaaaabbbbccccddddeeeeeeeeeeee"

ROLE_WRITE = "Microsoft.Authorization/roleAssignments/write"
ROLE_DELETE = "Microsoft.Authorization/roleAssignments/delete"
RESOURCE_ACTIONS = [
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.ContainerService/managedClusters/write",
    "Microsoft.KeyVault/vaults/write",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Network/virtualNetworks/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/write",
    "Microsoft.Cache/redisEnterprise/write",
]

ABAC = (
    "@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] "
    "ForAnyOfAnyValues:GuidEquals{acdd72a7-3385-48ef-bd42-f606fba81ae7}"
)

# The shape that fails apply while preflight passes: roleAssignments/write is
# permitted, but only for a ServicePrincipal, so the Key Vault Secrets Officer
# grant is refused for omitting principal_type rather than for lacking a role.
ABAC_PRINCIPAL_TYPE = (
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR "
    "(@Request[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "StringEqualsIgnoreCase 'ServicePrincipal'))"
)

# The same shape widened to admit human deployers. Here terraform_principal_type
# is the right advice, so the pinned-condition verdict must not fire on it.
ABAC_PRINCIPAL_TYPE_ANY = (
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR "
    "(@Request[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal', 'User'}))"
)

# Pinned on delete only. Nothing constrains who a new assignment may target, so
# the deployer's own grant goes through and only its removal is fenced.
ABAC_PRINCIPAL_TYPE_DELETE_ONLY = (
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (%s)) AND "
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR "
    "(@Resource[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "StringEqualsIgnoreCase 'ServicePrincipal'))" % ABAC
)


# Pinned on delete with no write clause at all. Truncating to "the text from the
# write action onwards" leaves the whole condition in hand, so the pin on delete
# reads as a pin on write and preflight hard-fails a subscription that would have
# applied cleanly.
ABAC_PRINCIPAL_TYPE_NO_WRITE_CLAUSE = (
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR "
    "(@Request[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "StringEqualsIgnoreCase 'ServicePrincipal'))"
)

# Azure's stock "Constrain roles and principal types" template. The AND sits
# inside the write clause's own constraint, so splitting on the first AND after
# the action drops the principalType half and the pin goes unseen.
ABAC_ROLES_AND_PRINCIPAL_TYPE = (
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR "
    "(@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] "
    "ForAnyOfAnyValues:GuidEquals{%s} AND "
    "@Request[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "StringEqualsIgnoreCase 'ServicePrincipal'))" % OWNER_GUID
)

# The same template with the sub-operation carve-out Azure adds so an assignment
# to a principal it cannot resolve still goes through. Its AND lands even earlier.
ABAC_PRINCIPAL_TYPE_SUBOP = (
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}) AND NOT "
    "SubOperationMatches{'Principal.NotFound'}) OR "
    "(@Request[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "StringEqualsIgnoreCase 'ServicePrincipal'))"
)

# No action test anywhere, so the constraint governs every action including write.
ABAC_PRINCIPAL_TYPE_NO_ACTION = (
    "@Request[Microsoft.Authorization/roleAssignments:PrincipalType] "
    "StringEqualsIgnoreCase 'ServicePrincipal'"
)


def granted(role_guid=OWNER_GUID, scope=SUB_SCOPE, condition=None, custom=False):
    return {
        "roleDefinitionId": role_guid,
        "scope": scope,
        "condition": condition,
        "conditionVersion": "2.0" if condition else None,
        "assignedToCustomRole": custom,
        "isBuiltIn": not custom,
        "principalType": "User",
    }


def decision(action, allowed=True, assignment=None, deny=None):
    return {
        "actionId": action,
        "accessDecision": "Allowed" if allowed else "NotAllowed",
        "isDataAction": False,
        "roleAssignment": assignment if allowed else None,
        "denyAssignment": deny,
        "auditAssignments": [],
        "timeToLiveInMs": 300000,
    }


def response(
    write=True,
    delete=True,
    resources=True,
    assignment=None,
    deny=None,
    refuse_resources=(),
):
    """A full nine-action checkAccess response for one scope."""
    assignment = assignment if assignment is not None else granted()
    out = [
        decision(ROLE_WRITE, write, assignment, deny),
        decision(ROLE_DELETE, delete, assignment),
    ]
    for action in RESOURCE_ACTIONS:
        allowed = resources and action not in refuse_resources
        out.append(decision(action, allowed, assignment))
    return out


def eligibility(role, scope=SUB_SCOPE):
    return {
        "properties": {
            "scope": scope,
            "endDateTime": "2026-12-01T00:00:00Z",
            "expandedProperties": {"roleDefinition": {"displayName": role}},
        }
    }


DENY = {"id": "deny-1", "displayName": "Landing zone RBAC lock"}

# What checkNameAvailability returns for a name that exists — byte-identical
# whether the resource belongs to this deployment or to a stranger's tenant.
TAKEN = {
    "nameAvailable": False,
    "available": False,
    "reason": "AlreadyExists",
    "message": "The specified name is already in use.",
}

# The names the default fixture derives (identifier "-dev", no hash).
PG = "langsmith-postgres-dev"
BLOB = "langsmithblobdev"
KV = "langsmith-kv-dev"
REDIS = "langsmith-redis-dev"
DNS = "langsmith-dev-ls"

ALL_GOOD = response()

CASES = [
    {
        "name": "Postgres capabilities validate the configured version and SKU",
        "ca_all": ALL_GOOD,
        "expect": [
            "[✓] Postgres capability API returned 2 SKU(s) and 2 version(s) in eastus",
            "[✓] postgres_version '16' is available in eastus",
            "[✓] postgres_sku_name 'GP_Standard_D2ds_v4' is available in eastus",
        ],
        "expect_calls": ["postgres flexible-server list-skus -l eastus -o json"],
        "reject": ["For prices please refer", "skipping regional availability"],
    },
    {
        "name": "an empty Postgres capability array is a definitive failure",
        "ca_all": ALL_GOOD,
        "pg_caps_raw": "[]",
        "expect": [
            "[✗] PostgreSQL Flexible Server is unavailable to the active subscription in eastus",
            "list-skus returned an empty array",
        ],
        "reject": ["postgres_version '16' is available", "unexpected response"],
    },
    {
        "name": "a Postgres capability CLI failure warns and skips",
        "ca_all": ALL_GOOD,
        "pg_caps_fail": True,
        "expect": [
            "[!] Postgres list-skus failed — skipping regional availability, version, and SKU checks",
        ],
        "reject": [
            "[✗] PostgreSQL Flexible Server is unavailable",
            "postgres_version '16' is available",
        ],
    },
    {
        "name": "unexpected Postgres capability stderr warns and skips",
        "ca_all": ALL_GOOD,
        "pg_caps_stderr": True,
        "expect": [
            "[!] Postgres list-skus wrote unexpected stderr — skipping regional availability, version, and SKU checks",
        ],
        "reject": [
            "[✗] PostgreSQL Flexible Server is unavailable",
            "postgres_version '16' is available",
            "For prices please refer",
        ],
    },
    {
        "name": "a reshaped Postgres capability response warns and skips",
        "ca_all": ALL_GOOD,
        "pg_caps_raw": json.dumps({"value": []}),
        "expect": [
            "[!] Postgres list-skus returned an unexpected response — skipping regional availability, version, and SKU checks",
        ],
        "reject": ["[✗] PostgreSQL Flexible Server is unavailable"],
    },
    {
        "name": "a non-JSON Postgres capability response warns and skips",
        "ca_all": ALL_GOOD,
        "pg_caps_raw": "<html>gateway timeout</html>",
        "expect": [
            "[!] Postgres list-skus returned an unexpected response — skipping regional availability, version, and SKU checks",
        ],
        "reject": ["[✗] PostgreSQL Flexible Server is unavailable"],
    },
    {
        "name": "an unavailable configured Postgres version fails",
        "ca_all": ALL_GOOD,
        "tfvars_extra": 'postgres_version = "15"',
        "expect": [
            "[✗] postgres_version '15' is not available in eastus. Available versions: 14, 16",
            "[✓] postgres_sku_name 'GP_Standard_D2ds_v4' is available in eastus",
        ],
    },
    {
        "name": "an unavailable configured Postgres SKU fails",
        "ca_all": ALL_GOOD,
        "tfvars_extra": 'postgres_sku_name = "MO_Standard_E2ds_v5"',
        "expect": [
            "[✓] postgres_version '16' is available in eastus",
            "[✗] postgres_sku_name 'MO_Standard_E2ds_v5' is not available in eastus",
            "Available SKUs: GP_Standard_D2ds_v4, GP_Standard_D4ds_v4",
        ],
    },
    {
        "name": "in-cluster Postgres skips the capability API",
        "ca_all": ALL_GOOD,
        "tfvars_extra": 'postgres_source = "in-cluster"',
        "expect": [
            "[✓] postgres_source = in-cluster — no Flexible Server capability check needed",
        ],
        "reject_calls": ["postgres flexible-server list-skus"],
    },
    {
        "name": "everything permitted passes at both scopes",
        "ca_all": ALL_GOOD,
        "expect": [
            f"[✓] roleAssignments/write permitted at {SUB_SCOPE}, granted by Owner held at",
            f"[✓] roleAssignments/write permitted at {RG_SCOPE}",
            f"[✓] Every resource type the deployment creates is writable at {SUB_SCOPE}",
        ],
        "reject": ["[✗]", "Falling back"],
    },
    {
        "name": "contributor is named as the granting role when it is the one that answered",
        "ca_all": response(assignment=granted(role_guid=CONTRIB_GUID)),
        "expect": ["granted by Contributor held at"],
    },
    {
        "name": "a custom role that grants the action is reported as custom, not as unknown",
        "ca_all": response(assignment=granted(role_guid=CUSTOM_GUID, custom=True)),
        "expect": [f"granted by custom role {CUSTOM_GUID} held at"],
    },
    {
        "name": "roleAssignments/write refused fails without inventing a reason",
        "ca_all": response(write=False),
        "expect": [
            f"[✗] roleAssignments/write is not permitted at {SUB_SCOPE}. All eight role assignments",
        ],
        "reject": ["by deny assignment", "PIM holds"],
    },
    {
        "name": "a deny assignment is named and called out as overriding Owner",
        "ca_all": response(write=False, deny=DENY),
        "expect": [
            '[✗] roleAssignments/write is denied at',
            'deny assignment "Landing zone RBAC lock"',
            "override every role assignment including Owner",
        ],
    },
    {
        "name": "an inactive PIM role turns the failure into an activation step",
        "ca_all": response(write=False),
        "eligibilities": [eligibility("Owner")],
        "expect": [
            "[✗] PIM holds these roles for this identity as eligible but not active: Owner at",
            "activating it (portal: PIM -> My roles -> Activate)",
        ],
    },
    {
        "name": "an ABAC condition on the granting assignment warns",
        "ca_all": response(assignment=granted(condition=ABAC)),
        "expect": [
            "[!] That grant carries an ABAC condition",
            "The modules assign: Storage Blob Data Contributor",
            "GuidEquals",
        ],
    },
    {
        # The variable declares what the principal is; it cannot make a human into
        # a service principal, so recommending it here sends the operator down a
        # dead end that costs an apply to discover.
        "name": "a condition pinned to ServicePrincipal does not recommend terraform_principal_type",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE)),
        "expect": [
            "[✗] The condition admits only ServicePrincipal targets",
            "declares the type rather than changing it",
            "keyvault_manage_terraform_admin_assignment = false",
        ],
        "reject": ['terraform_principal_type = "User"'],
    },
    {
        "name": "a pinned condition is silent once the grant it rejects is turned off",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE)),
        "tfvars_extra": "keyvault_manage_terraform_admin_assignment = false",
        "expect": ["keyvault_manage_terraform_admin_assignment is already false"],
        "reject": ["[✗] The condition admits only ServicePrincipal targets"],
    },
    {
        # Nothing to work around: the request this deployer sends already matches.
        "name": "a pinned condition is not a blocker for a service principal deployer",
        "env": {"ARM_CLIENT_ID": "app-guid"},
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE)),
        "expect": [
            "The condition tests principalType",
            'terraform_principal_type = "ServicePrincipal"',
        ],
        "reject": ["The condition admits only ServicePrincipal targets"],
    },
    {
        "name": "a principalType condition that admits User names terraform_principal_type",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE_ANY)),
        "expect": [
            "The condition tests principalType",
            'terraform_principal_type = "User"',
        ],
        "reject": ["The condition admits only ServicePrincipal targets"],
    },
    {
        "name": "a principalType condition on delete alone does not block the write",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE_DELETE_ONLY)),
        "expect": ["The condition tests principalType"],
        "reject": ["The condition admits only ServicePrincipal targets"],
    },
    {
        "name": "an ABAC condition on roles alone does not mention principal_type",
        "ca_all": response(assignment=granted(condition=ABAC)),
        "reject": ["terraform_principal_type"],
    },
    {
        # Nothing constrains write, so telling the operator to disable the Key
        # Vault grant would cost them a working assignment for no reason.
        "name": "a condition with no write clause is not read as a pin",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE_NO_WRITE_CLAUSE)),
        "expect": ["[!] That grant carries an ABAC condition"],
        "reject": ["The condition admits only ServicePrincipal targets"],
    },
    {
        "name": "Azure's stock roles-and-principal-types template is read as a pin",
        "ca_all": response(assignment=granted(condition=ABAC_ROLES_AND_PRINCIPAL_TYPE)),
        "expect": [
            "[✗] The condition admits only ServicePrincipal targets",
            "keyvault_manage_terraform_admin_assignment = false",
        ],
        "reject": ['terraform_principal_type = "User"'],
    },
    {
        "name": "the Principal.NotFound carve-out does not hide the pin",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE_SUBOP)),
        "expect": [
            "[✗] The condition admits only ServicePrincipal targets",
            "keyvault_manage_terraform_admin_assignment = false",
        ],
        "reject": ['terraform_principal_type = "User"'],
    },
    {
        # An unqualified constraint applies to write along with everything else.
        "name": "a pin with no action test at all still counts",
        "ca_all": response(assignment=granted(condition=ABAC_PRINCIPAL_TYPE_NO_ACTION)),
        "expect": ["[✗] The condition admits only ServicePrincipal targets"],
        "reject": ['terraform_principal_type = "User"'],
    },
    {
        "name": "a refused resource write fails and names the action",
        "ca_all": response(refuse_resources=("Microsoft.Cache/redisEnterprise/write",)),
        "expect": ["[✗] Not permitted at", "Microsoft.Cache/redisEnterprise/write"],
        "reject": ["[✗] roleAssignments/write"],
    },
    {
        "name": "no delete permission warns about destroy without failing apply",
        "ca_all": response(delete=False),
        "expect": ["[!] roleAssignments/delete is not permitted at", "terraform destroy"],
        "reject": ["[✗]"],
    },
    {
        "name": "permitted at the subscription but denied on the resource group fails on the scope",
        "ca_sub": ALL_GOOD,
        "ca_rg": response(write=False, deny=DENY),
        "expect": [
            f"[✓] roleAssignments/write permitted at {SUB_SCOPE}",
            f"[✗] roleAssignments/write is denied at {RG_SCOPE}",
        ],
    },
    {
        "name": "a scope that does not answer is reported, and the others still render",
        "ca_sub": ALL_GOOD,
        "ca_rg_fail": True,
        "expect": [
            f"[!] checkAccess did not answer at {RG_SCOPE}",
            f"[✓] roleAssignments/write permitted at {SUB_SCOPE}",
        ],
        "reject": ["Falling back"],
    },
    {
        "name": "checkAccess unavailable everywhere falls back and says so",
        "ca_fail": True,
        "held": "Owner\nReader",
        "expect": [
            "[!] checkAccess (Microsoft.Authorization/checkAccess, 2018-09-01-preview) did not answer",
            "cannot see deny assignments, ABAC conditions, or custom roles",
            "[✓] Holds Owner,Reader at or above the subscription",
        ],
    },
    {
        "name": "fallback fails when no qualifying role name is held",
        "ca_fail": True,
        "held": "Reader\nMonitoring Contributor",
        "expect": [
            "[✗] No Owner, User Access Administrator, or Role Based Access Control Administrator",
            "Roles held: Reader,Monitoring Contributor",
            "custom role carrying roleAssignments/write would also work and is not detected",
        ],
    },
    {
        "name": "fallback with nothing readable refuses to render a verdict",
        "ca_fail": True,
        "assignments_fail": True,
        "expect": ["[✗] No role assignments could be read for this principal"],
        "reject": ["[✓] Holds"],
    },
    {
        "name": "a reshaped response counts as unavailable rather than as a verdict",
        "ca_all_raw": json.dumps({"value": [decision(ROLE_WRITE, True, granted())]}),
        "held": "Owner",
        "expect": ["Falling back to a role-name check"],
        "reject": ["[✓] roleAssignments/write permitted"],
    },
    {
        "name": "a non-JSON response counts as unavailable",
        "ca_all_raw": "<html>gateway timeout</html>",
        "held": "Owner",
        "expect": ["Falling back to a role-name check"],
    },
    {
        "name": "an empty array counts as unavailable rather than as nothing permitted",
        "ca_all_raw": "[]",
        "held": "Owner",
        "expect": ["Falling back to a role-name check"],
        "reject": ["[✗] roleAssignments/write is not permitted"],
    },
    {
        "name": "ARM_CLIENT_ID makes the service principal the Subject, not the operator",
        "env": {"ARM_CLIENT_ID": "app-guid"},
        "ca_all": ALL_GOOD,
        "expect": [
            "[!] ARM_CLIENT_ID is set",
            f"service principal from ARM_CLIENT_ID (object ID {SP_OID})",
        ],
        "assert_subject": SP_OID,
        "reject_calls": ["roleEligibilityScheduleInstances"],
    },
    {
        "name": "a denied service principal is not handed the operator's PIM eligibilities",
        "env": {"ARM_CLIENT_ID": "app-guid"},
        "ca_all": response(write=False),
        "eligibilities": [eligibility("Owner")],
        "expect": [
            "[!] Terraform will authenticate as a principal other than the one running this script",
        ],
        "reject": ["PIM holds these roles"],
    },
    {
        "name": "an invalid identifier drops the resource group scope instead of building a bad URL",
        "tfvars_identifier": '"-Prod Corp"',
        "ca_all": ALL_GOOD,
        "expect": ["[!] terraform.tfvars: identifier is not a valid resource-name suffix"],
        "reject_calls": ["resourceGroups"],
    },
    {
        "name": "an empty identifier still yields a resource group scope",
        "tfvars_identifier": '""',
        "ca_all": ALL_GOOD,
        "expect_calls": [f"{SUB_SCOPE}/resourceGroups/langsmith-rg/providers"],
    },
    {
        # name_suffix_salt exists so a deployment whose four global names got
        # burned can rotate them. Preflight has to mix it into the hash the same
        # way local.uniq_suffix does, or bumping the salt leaves preflight
        # checking the old names and reporting the collision it was bumped to
        # escape. Redis is asserted because it is the one name printed in full.
        "name": "name_suffix_salt rotates the derived global names",
        "tfvars_extra": 'name_prefix = "prod"\nunique_resource_names = true\nname_suffix_salt = "2"',
        "ca_all": ALL_GOOD,
        "expect": ["ls-redis-prod-4352a7"],
        "reject": ["ls-redis-prod-8a57d8"],
    },
    {
        # The unsalted counterpart, pinning the default derivation so a change to
        # the hash inputs cannot pass unnoticed.
        "name": "an empty salt leaves the derived names unchanged",
        "tfvars_extra": 'name_prefix = "prod"\nunique_resource_names = true',
        "ca_all": ALL_GOOD,
        "expect": ["ls-redis-prod-8a57d8"],
    },
    {
        # The redis module provisions Microsoft.Cache/redisEnterprise via azapi,
        # not the classic Microsoft.Cache/redis. Asking about the classic action
        # passed a principal that could not create the actual cluster.
        "name": "Redis is checked as redisEnterprise, not as classic Azure Cache",
        "ca_all": ALL_GOOD,
        "assert_actions": ["Microsoft.Cache/redisEnterprise/write"],
        "reject_actions": ["Microsoft.Cache/redis/write"],
    },
    {
        # The RBAC scope used to be hardcoded to "langsmith-rg" + the legacy
        # identifier, so it asked about a resource group Terraform never creates
        # once unique_resource_names moved the base to "ls". Both halves are
        # asserted here: name_prefix wins over identifier, and the base follows
        # unique_resource_names.
        "name": "the resource group scope follows name_prefix and unique_resource_names",
        "tfvars_extra": 'name_prefix = "prod"\nunique_resource_names = true',
        "ca_all": ALL_GOOD,
        "expect_calls": [f"{SUB_SCOPE}/resourceGroups/ls-rg-prod/providers"],
        "reject_calls": ["langsmith-rg"],
    },
    {
        "name": "a bring-your-own VNet is checked as its own scope",
        "tfvars_extra": f'vnet_id = "{VNET_ID}"',
        "ca_all": ALL_GOOD,
        "ca_vnet": response(write=False, deny=DENY),
        "expect": [f"[✗] roleAssignments/write is denied at {VNET_ID}"],
        "expect_calls": [VNET_ID],
    },
    {
        "name": "a malformed vnet_id is dropped rather than interpolated",
        "tfvars_extra": 'vnet_id = "https://evil.example.com/x"',
        "ca_all": ALL_GOOD,
        "expect": ["[!] terraform.tfvars: vnet_id is not a VNet resource ID"],
        "reject_calls": ["evil.example.com"],
    },
    {
        "name": "an unresolvable principal skips the RBAC check entirely",
        "no_graph": True,
        "ca_all": ALL_GOOD,
        "expect": ["[!] Could not resolve an object ID", "[!] Skipping RBAC check"],
        "reject": ["[✗] roleAssignments/write"],
    },
    {
        # checkNameAvailability answers a global question and has no ownership
        # dimension, so every name a deployment already created comes back
        # taken. Reading Terraform state first is what stops the second
        # `make preflight` of a live deployment from failing on its own
        # resources. The DNS label is included because it lives under a
        # different state attribute than the other three.
        "name": "names this deployment already created are not collisions",
        "tfvars_extra": f'dns_label = "{DNS}"',
        "ca_all": ALL_GOOD,
        "name_availability": TAKEN,
        "tfstate_names": [PG, BLOB, KV],
        "tfstate_dns_labels": [DNS],
        "expect": [
            f"[✓] Postgres: '{PG}' is already deployed and tracked in Terraform state",
            f"[✓] Storage account: '{BLOB}' is already deployed",
            f"[✓] Key Vault: '{KV}' is already deployed",
            f"[✓] Public IP DNS label: '{DNS}' is already deployed",
        ],
        "reject": ["ALREADY TAKEN"],
    },
    {
        # domain_name_label only reaches state through azurerm_public_ip.agw,
        # which exists under ingress_controller = "agic" alone. On the default
        # nginx path the label rides a Service annotation on an AKS-managed IP,
        # so state cannot vouch for it and the subscription has to.
        "name": "a DNS label held by this subscription is not a collision",
        "tfvars_extra": f'dns_label = "{DNS}"',
        "ca_all": ALL_GOOD,
        "name_availability": TAKEN,
        "dns_held": "1",
        "expect": [
            f"[✓] Public IP DNS label: '{DNS}' is already held by a resource in this subscription",
        ],
        "reject": [f"[✗] Public IP DNS label: '{DNS}' is ALREADY TAKEN"],
    },
    {
        "name": "a DNS label held by a stranger is still a collision",
        "tfvars_extra": f'dns_label = "{DNS}"',
        "ca_all": ALL_GOOD,
        "name_availability": TAKEN,
        "dns_held": "0",
        "expect": [f"[✗] Public IP DNS label: '{DNS}' is ALREADY TAKEN globally"],
    },
    {
        # Terraform hashes the tfvars subscription into the four global names and
        # deploys there; every az call here answers for the CLI's active one. A
        # silent divergence means the report describes neither.
        "name": "a tfvars subscription that is not the active one fails",
        "ca_all": ALL_GOOD,
        "tfvars_sub": "99999999-9999-9999-9999-999999999999",
        "expect": [
            "[✗] terraform.tfvars sets subscription_id = 99999999-9999-9999-9999-999999999999",
            f"the active CLI subscription is {SUB}",
            "az account set --subscription 99999999-9999-9999-9999-999999999999",
        ],
    },
    {
        "name": "a matching subscription passes without comment",
        "ca_all": ALL_GOOD,
        "reject": ["but the active CLI subscription is"],
    },
    {
        "name": "a taken name with no state behind it still fails",
        "ca_all": ALL_GOOD,
        "name_availability": TAKEN,
        "expect": [
            f"[✗] Postgres: '{PG}' is ALREADY TAKEN globally",
            f"[✗] Key Vault: '{KV}' is ALREADY TAKEN globally",
        ],
        "reject": ["tracked in Terraform state"],
    },
    {
        # State exempts a name, not the run: a half-built deployment must still
        # fail on the names it has not created yet.
        "name": "state exempts only the names it actually holds",
        "ca_all": ALL_GOOD,
        "name_availability": TAKEN,
        "tfstate_names": [PG],
        "expect": [
            f"[✓] Postgres: '{PG}' is already deployed",
            f"[✗] Key Vault: '{KV}' is ALREADY TAKEN globally",
        ],
    },
    {
        # A soft-deleted vault is ours and still holds the name, but it is in
        # neither Terraform state nor `az keyvault list`, so state cannot see it
        # and the generic "already in use" names no remedy.
        "name": "a soft-deleted Key Vault is named as such, with the remedy",
        "ca_all": ALL_GOOD,
        "name_availability": TAKEN,
        "kv_deleted": 1,
        "expect": [
            f"[✗] Key Vault: '{KV}' is soft-deleted",
            f"az keyvault recover --name {KV}",
        ],
        "reject": [f"Key Vault: '{KV}' is ALREADY TAKEN"],
    },
    {
        # Redis has no working CheckNameAvailability, so it is checked against
        # the subscription instead — which was equally blind to ownership.
        "name": "a Redis left over from a failed apply still fails",
        "ca_all": ALL_GOOD,
        "redis_hit": 1,
        "expect": [f"[✗] Redis: '{REDIS}' already exists in this subscription"],
    },
    {
        "name": "a Redis that Terraform already manages does not",
        "ca_all": ALL_GOOD,
        "redis_hit": 1,
        "tfstate_names": [REDIS],
        "expect": [f"[✓] Redis: '{REDIS}' is already deployed and tracked in Terraform state"],
        "reject": ["[✗] Redis"],
    },
    {
        "name": "an ARM_SUBSCRIPTION_ID mismatch fails before any verdict is trusted",
        "env": {"ARM_SUBSCRIPTION_ID": "99999999-9999-9999-9999-999999999999"},
        "ca_all": ALL_GOOD,
        "expect": ["[✗] ARM_SUBSCRIPTION_ID is 99999999", "every check in this script reads"],
    },
]


def build_case(case, index):
    root = WORKDIR / f"case{index:02d}"
    infra = root / "infra"
    (infra / "scripts").mkdir(parents=True)
    shutil.copy2(SOURCE_SCRIPT, infra / "scripts" / "preflight.sh")

    identifier = case.get("tfvars_identifier", '"-dev"')
    (infra / "terraform.tfvars").write_text(
        f'subscription_id = "{case.get("tfvars_sub", SUB)}"\n'
        'location    = "eastus"\n'
        f"identifier  = {identifier}\n"
        f"{case.get('tfvars_extra', '')}\n"
    )
    (infra / "secrets.auto.tfvars").write_text('langsmith_license_key = "lsv2_pt_stub"\n')

    fixture = root / "fixtures"
    fixture.mkdir()
    (fixture / "sub_id").write_text(SUB)
    (fixture / "principal_id").write_text(case.get("principal_id", USER_OID))
    (fixture / "sp_principal_id").write_text(SP_OID)
    if "ARM_CLIENT_ID" not in case.get("env", {}):
        (fixture / "user_type").write_text("user")

    for key, name in (
        ("ca_all", "ca_all.json"),
        ("ca_sub", "ca_sub.json"),
        ("ca_rg", "ca_rg.json"),
        ("ca_vnet", "ca_vnet.json"),
    ):
        if key in case:
            (fixture / name).write_text(json.dumps(case[key]))
    if "ca_all_raw" in case:
        (fixture / "ca_all.json").write_text(case["ca_all_raw"])

    (fixture / "eligibilities.json").write_text(
        json.dumps({"value": case.get("eligibilities", [])})
    )
    if "held" in case:
        (fixture / "held").write_text(case["held"])
    if "pg_caps_raw" in case:
        (fixture / "pg_caps.json").write_text(case["pg_caps_raw"])
    if "name_availability" in case:
        (fixture / "name_availability.json").write_text(json.dumps(case["name_availability"]))
    for key in ("kv_deleted", "redis_hit", "dns_held"):
        if key in case:
            (fixture / key).write_text(str(case[key]))

    # Preflight reads the local state file when no backend is initialised, which
    # is the state a customer running `make preflight` before `make init` is in.
    if "tfstate_names" in case or "tfstate_dns_labels" in case:
        resources = [
            {"type": "stub", "instances": [{"attributes": {"name": value}}]}
            for value in case.get("tfstate_names", [])
        ] + [
            {"type": "azurerm_public_ip",
             "instances": [{"attributes": {"domain_name_label": value}}]}
            for value in case.get("tfstate_dns_labels", [])
        ]
        (infra / "terraform.tfstate").write_text(
            json.dumps({"version": 4, "resources": resources})
        )

    for flag in ("no_graph", "ca_fail", "ca_rg_fail", "ca_sub_fail", "ca_vnet_fail",
                 "assignments_fail", "pg_caps_fail", "pg_caps_stderr"):
        if case.get(flag):
            (fixture / flag).write_text("1")

    return infra / "scripts" / "preflight.sh", fixture


def run_case(case, index):
    script, fixture = build_case(case, index)

    env = dict(os.environ)
    env["PATH"] = f"{STUB_DIR}:{env['PATH']}"
    env["FIXTURE_DIR"] = str(fixture)
    for key in ("ARM_CLIENT_ID", "ARM_SUBSCRIPTION_ID", "ARM_TENANT_ID",
                "ARM_USE_MSI", "ARM_USE_OIDC"):
        env.pop(key, None)
    env.update(case.get("env", {}))

    proc = subprocess.run(
        ["bash", str(script)], capture_output=True, text=True, env=env, timeout=120
    )
    output = ANSI.sub("", proc.stdout + proc.stderr)
    if "STUB: unhandled" in output or "STUB: unexpected" in output:
        return False, [line for line in output.splitlines() if "STUB:" in line]

    calls_path = fixture / "calls.log"
    calls = calls_path.read_text() if calls_path.exists() else ""

    problems = []
    for needle in case.get("expect", []):
        if needle not in output:
            problems.append(f"missing: {needle}")
    for needle in case.get("reject", []):
        if needle in output:
            problems.append(f"unexpected: {needle}")
    for needle in case.get("expect_calls", []):
        if needle not in calls:
            problems.append(f"never requested: {needle}")
    for needle in case.get("reject_calls", []):
        if needle in calls:
            problems.append(f"unexpectedly requested: {needle}")

    if "assert_subject" in case:
        body_path = fixture / "last_body.json"
        if not body_path.exists():
            problems.append("no checkAccess body was sent")
        else:
            got = json.loads(body_path.read_text())["Subject"]["Attributes"]["ObjectId"]
            if got != case["assert_subject"]:
                problems.append(f"Subject was {got}, expected {case['assert_subject']}")

    # The stub answers from this file's own ACTIONS list rather than from the
    # request, so nothing above notices when the script asks about an action the
    # deployment never performs. These two read the body the script actually sent.
    if "assert_actions" in case or "reject_actions" in case:
        body_path = fixture / "last_body.json"
        if not body_path.exists():
            problems.append("no checkAccess body was sent")
        else:
            sent = {a["Id"] for a in json.loads(body_path.read_text())["Actions"]}
            for action in case.get("assert_actions", []):
                if action not in sent:
                    problems.append(f"never asked about: {action}")
            for action in case.get("reject_actions", []):
                if action in sent:
                    problems.append(f"unexpectedly asked about: {action}")

    if problems:
        rendered = [
            line for line in output.splitlines()
            if any(mark in line for mark in ("[✓]", "[!]", "[✗]"))
            and "Microsoft." not in line.split("]")[-1][:30]
        ]
        problems.append("--- rendered ---")
        problems.extend(rendered)
    return not problems, problems


def main():
    for required in (SOURCE_SCRIPT, STUB_DIR / "az"):
        if not required.exists():
            print(f"not found: {required}")
            return 1
    failures = 0
    try:
        for index, case in enumerate(CASES, start=1):
            ok, problems = run_case(case, index)
            print(f"{'PASS' if ok else 'FAIL'}  {case['name']}")
            if not ok:
                failures += 1
                for line in problems:
                    print(f"        {line}")
    finally:
        shutil.rmtree(WORKDIR, ignore_errors=True)
    print(f"\n{len(CASES) - failures}/{len(CASES)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
