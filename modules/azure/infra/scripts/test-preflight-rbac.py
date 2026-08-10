"""Exercise preflight.sh's RBAC block against a stubbed az CLI.

The checks worth testing are the ones you cannot produce on demand in a real
subscription: a deny assignment that overrides Owner, a PIM role held but not
activated, an ABAC-conditioned grant, and a preview API that changes shape or
stops answering. Each case builds an infra directory, copies the real script into
it so INFRA_DIR resolves inside the fixture, runs it with a stub `az` first on
PATH, and asserts on substrings of the rendered output.

Usage: python3 test_rbac_preflight.py
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
    "Microsoft.Cache/redis/write",
]

ABAC = (
    "@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] "
    "ForAnyOfAnyValues:GuidEquals{acdd72a7-3385-48ef-bd42-f606fba81ae7}"
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

ALL_GOOD = response()

CASES = [
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
        "reject": ["deny assignment", "PIM holds"],
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
        "name": "a refused resource write fails and names the action",
        "ca_all": response(refuse_resources=("Microsoft.Cache/redis/write",)),
        "expect": ["[✗] Not permitted at", "Microsoft.Cache/redis/write"],
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
        f'subscription_id = "{SUB}"\n'
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

    for flag in ("no_graph", "ca_fail", "ca_rg_fail", "ca_sub_fail", "ca_vnet_fail",
                 "assignments_fail"):
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
