# Azure quickstart wizard: open UX issues

Running list from walking the wizard. Line numbers are against this worktree
(`test/azure-e2e` at 906eccc), where `quickstart.sh` is currently longest.
Nothing here is filed as a GitHub issue yet.

## 1. Redis SKU asked twice (bug, not just UX)

`quickstart.sh:1378` and `quickstart.sh:1388` are the same block twice, a merge
artifact: `azure-amr-sku` has one copy, the merge into `test/azure-e2e` produced
two. The second copy offers `Balanced_B0` as its default and overwrites
`AMR_SKU`, so a prod run that took the offered `Balanced_B3` and then pressed
Enter leaves with B0, the SKU that returned InsufficientCapacity in eastus.

On the prod profile it is worse than a silent downgrade: prod sets
`REDIS_HA="true"` alongside `Balanced_B3` (`quickstart.sh:1356`), so the reset to
B0 produces a pair the module rejects, and plan fails before it can price
anything.

```
Error: Invalid value for variable
  on main.tf line 750, in module "redis":
   750:   high_availability = var.redis_high_availability
     var.amr_sku is "Balanced_B0"
     var.high_availability is true
Balanced_B0 cannot run high availability. Use Balanced_B1 or larger, or set
redis_high_availability = false.
```

Confirmed live. Every prod run that presses Enter at the second prompt ends here.

Fix: delete the second block, keep the one whose default is `$AMR_SKU`. Then
validate the pair at the prompt: the wizard writes `amr_sku` and
`redis_high_availability` independently (`quickstart.sh:1883`), so even with the
duplicate gone, an operator on the prod profile who types `Balanced_B0` at the SKU
prompt gets the same plan failure with nothing said at the time. Re-ask, or offer
to turn HA off, using the wording from `redis/variables.tf:58` since it already
names both remedies.

## 2. No way to name the resource group, VNet, or new cluster

Overrides exist for the four globally-unique names (`postgres_name`,
`redis_name`, `storage_account_name`, `keyvault_name`). The regional names are
derived with no escape hatch (`main.tf:45`): `ls-rg-<suffix>`,
`ls-vnet-<suffix>`, `ls-aks-<suffix>`, and the base itself is a hardcoded
`ls`/`langsmith` switch. Attaching to existing resources is covered; creating
new ones under a customer's naming standard is not.

Fix: `resource_group_name`, `vnet_name`, `cluster_name`, empty default meaning
derived, plus a `name_base` variable defaulting to today's switch. Most requests
are a corporate prefix rather than per-resource surgery, so `name_base` answers
more of them than the other three. Keep all four out of the interactive path:
document them in `terraform.tfvars.example` and the README override table, and
point at them from the review screen. Note in the docs that changing any of
these after an apply is a destroy and recreate.

## 3. The Key Vault Secrets Officer prompt never says what the grant is

`quickstart.sh:1460` asks whether Terraform may create its own grant, and
explains only why an operator might answer no. It never says what the role
confers or where it lands, and a `no` leaves the operator with nothing to hand
their tenant admin.

Fix: one hint line saying the role is create, read, update, delete and list
secrets, scoped to that vault alone, and that Owner and Contributor do not imply
it because the vault runs in RBAC mode. On a `no`, print the
`az role assignment create --role "Key Vault Secrets Officer"` command with the
vault scope (it already exists at `TROUBLESHOOTING.md:404`) and say the grant
has to exist before `make apply`. Today the only equivalent explanation is a
comment written into the generated tfvars, which nobody reads mid-wizard.

## 4. `name_prefix` and `owner` are both underexplained

`name_prefix` is presented as "Deployment name" (`quickstart.sh:415`) while the
variable says prefix and the value is applied as a suffix. Section 2 does not
say that the same value becomes the `environment` tag, feeds the
`unique_resource_names` hash, and cannot be changed later without building an
entirely new deployment.

`owner` is prompted as "Owner tag (team or person, for cost attribution)" and
defaults to `platform-team`. It is free text on the `owner` tag and grants
nobody anything, which the prompt does not say either way, so it reads like it
might control access. The `platform-team` default also means most deployments
carry a meaningless owner tag.

The wizard never asks about `environment`, so an operator who wants
`name_prefix = "prod-eastus"` with `environment = "prod"` has to hand-edit the
generated tfvars.

Fix: rename the prompt to match what the value does, list the three places it
lands, and state the rename-is-a-new-deployment consequence at the prompt rather
than only in the hint block. For `owner`, say it is a tag only, and drop the
default so a blank answer omits the tag instead of asserting a fake owner.

## 5. No documented path for running as a service principal

`preflight.sh:123` detects `ARM_CLIENT_ID` and warns that Terraform will
authenticate as that principal rather than the `az login` user, and
`README.md:513` documents that the preflight reports it. Neither says how to
choose that path deliberately: which of `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` /
`ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` to set, whether
`az login --service-principal` is equivalent, or which roles the SP needs.
`PERMISSIONS.md` keys its role table to "the deploying identity" without saying
how to become one. This is the normal shape for a customer with a CI pipeline or
a subscription that refuses role assignments to users, which is the same
condition that drives the answer in issue 3.

Fix: a short section in `PERMISSIONS.md` covering both auth routes, the roles the
principal needs, and the one behavior difference that matters (the Key Vault
grant path and its `principal_type`).

## 6. The quickstart never says it creates a resource group or object storage

Every resource lands in a Terraform-created resource group (`main.tf:296`,
deleting it deletes everything), and LangSmith requires a storage account for
run artifacts. Neither has a section, neither appears on the review screen
(`quickstart.sh:1655` onward), and `blob_ttl_*` values get written into tfvars
without ever being asked or explained. Storage surfaces only as an aside about
name uniqueness and as a firewall allowlist mention. A customer with a storage
policy (no public network access, CMK, a required SKU) has no signal that a
storage account is part of this at all.

Fix: the review screen should list what gets created, not only what was asked.
Add the resource group name, the storage account, and on prod the Log Analytics
workspace, and give blob TTL a line in section 7 or its own short section so the
retention defaults are a visible choice.

## 7. The TLS menu presents Let's Encrypt and DNS-01 as alternatives

Both are Let's Encrypt. The choice is the challenge type, HTTP-01 or DNS-01, and
`letsencrypt_email` is required for both (`variables.tf:578`). Because the menu
at `quickstart.sh:1186` labels option 2 "Let's Encrypt" and option 3 "DNS-01", an
operator who picks DNS-01 then gets "Let's Encrypt requires an email for your
ACME account" and reasonably reads it as a bug. Asking is correct; the labels are
what is wrong.

Fix: label them "Let's Encrypt (HTTP-01)" and "Let's Encrypt (DNS-01)", and word
the email prompt as the ACME account email rather than a Let's Encrypt-specific
one.

Second problem in the same section: after picking DNS-01, the wizard asks a DNS
approach question whose first option is invalid. `quickstart.sh:1272` offers
"Azure public IP DNS label" alongside "Custom domain", and its own hint says the
label is only usable with HTTP-01. Picking it on the DNS-01 path leaves
`LANGSMITH_DOMAIN` empty and still writes `create_dns_zone = true`, and nothing
validates that pair: no variable validation ties `tls_certificate_source =
"dns01"` to a non-empty `langsmith_domain`, so the DNS module receives an empty
domain. Skip the question entirely on DNS-01 and go straight to the custom domain
prompt, and add the missing validation so a hand-written tfvars fails at plan.

## 8. The wizard never asks whether apply runs as a user or a service principal

`terraform_principal_type` exists (`variables.tf:156`) and is commented out in
`terraform.tfvars.example:404`. The wizard never asks and never writes it, so the
only signal is `preflight.sh:123` noticing `ARM_CLIENT_ID` after the fact.

The answer drives three things: `principal_type` on the role assignments, the
default for the Key Vault Secrets Officer question in issue 3 (an ABAC condition
permitting only ServicePrincipal is exactly the case where a user must answer
no), and which principal the preflight should probe. Ask it once in section 2
next to the subscription ID, write `terraform_principal_type`, and use it to set
the section 8 default. Pair it with the `PERMISSIONS.md` section from issue 5, so
the prompt has something to link to.

## 9. The RBAC check reports one problem as several failures

From a live preflight run against a subscription where the operator holds Owner
and User Access Administrator as PIM-eligible but not activated:

- `roleAssignments/write is not permitted` prints once per scope, subscription
  and resource group, with the same trailing sentence both times
  (`preflight.sh:373`). The resource group inherits from the subscription, so the
  second line is the same fact.
- `roleAssignments/delete is not permitted` repeats the same way
  (`preflight.sh:389`).
- The PIM finding that explains all of them prints last (`preflight.sh:406`),
  after two interleaved passes, so the output reads as three independent
  blockers rather than one activation click.
- Both `write` lines end with "All eight role assignments in the Azure modules
  need it" (`preflight.sh:373`, and `:390` for `delete`). The sentence gives a
  count and no roles, so it neither tells the operator what will be assigned nor
  gives them anything to send an admin. The count is also wrong for most runs:
  three of the eight are AGIC-only (`k8s-cluster/main.tf:699,708,727`), one is
  DNS-01-only (`dns/main.tf:45`), one is bastion-only
  (`bastion/main.tf:143`), and both Key Vault ones are toggleable
  (`keyvault/main.tf:137,164`). A default deployment creates three.
- That PIM line lists all twelve eligible roles in one sentence, including API
  Management Service Contributor and SQL Server Contributor. The script already
  knows which built-ins carry the action: `preflight.sh:431` checks for Owner,
  User Access Administrator and Role Based Access Control Administrator by name.
- At least one of those twelve does not exist in the operator's portal. API
  Management Service Contributor showed in our output and not under PIM -> My
  roles, so the remediation we print names a role they cannot find, which makes
  the whole finding read as unreliable.

Fix: collapse the per-scope duplicates into one finding naming both scopes, or
report the resource group only when its answer differs from the subscription's.
Name the roles Terraform assigns, or drop the count and say the deployment
assigns roles to its own managed identities.
Lead with the PIM finding when `denied_write` is set, and print only the eligible
roles that carry `roleAssignments/write` (Owner, User Access Administrator, Role
Based Access Control Administrator), dropping the rest rather than listing them.
That also sidesteps the portal mismatch instead of trying to explain it. Keeping
the verdict at fail is right, since nothing can apply until the role is activated.

Open question on the mismatch: `preflight.sh:400` prints every entry in the
`roleEligibilityScheduleInstances?$filter=asTarget()` response unfiltered, and the
screenshot shows all of them at the same subscription scope, so scope does not
explain it. `properties.memberType` and `properties.status` are the fields to read
off a live response next time one is in front of us. Worth answering only if we
keep printing roles beyond the three that matter.

Note while in that code: the comment at `preflight.sh:275` says all four GUIDs in
`ROLE_NAMES` carry `roleAssignments/write`. Contributor does not, its NotActions
exclude `Microsoft.Authorization/*/Write`. The dict is only used to label a role
on an allowed decision, so nothing misbehaves, but the fix above needs the
correct set of three.

## 10. The name check calls an invalid name "ALREADY TAKEN globally"

From a live run with `name_prefix = "prod-ecliptos"`:

```
[✓] Storage account: 'lsblobprodecliptos9f64c9' is available
[✗] Key Vault: 'ls-kv-prod-ecliptos-9f64c9' is ALREADY TAKEN globally. The vault
    name 'ls-kv-prod-ecliptos-9f64c9' is invalid. A vault's name must be between
    3-24 alphanumeric …
```

The vault name is 26 characters, so nothing is taken: Azure rejected the shape.
`_check_name` at `preflight.sh:609` maps `nameAvailable: false` straight to
"ALREADY TAKEN globally" and ignores the `reason` field, which all three
checkNameAvailability APIs return as `AlreadyExists` or `Invalid`. The Azure
message appended after our own headline then contradicts it, in the same line.

Fix: branch on `reason`. `AlreadyExists` keeps today's wording; `Invalid` should
say the name is not a legal Azure name and print the rule, since the remedy is a
shorter `name_prefix` rather than a different one.

## 11. Nothing enforces the name-length ceiling at the prompt

The same run explains itself: storage came out at exactly 24 characters and
passed, the vault at 26 and failed, because the vault keeps its hyphens inside
the same limit. Section 2 hints "Keep it under ~12 chars" (`quickstart.sh:385`)
and then accepts the 13-character `prod-ecliptos` without checking. The operator
finds out at preflight, or at plan through the precondition at `main.tf:314`,
either way after the whole interview is over.

Fix: compose the vault and storage names at the prompt and re-ask when either
busts its limit, quoting the name it produced and its length per issue 12. The
wizard already knows every input the derivation needs, and the plan-time
precondition stays as the backstop for a hand-written tfvars.

## 12. A length failure should say how long the name actually is

Rule for all three sites: print the name, the count it came to, and the limit.
Reading a rule and counting characters by hand is the reader's job only because
we made it theirs, and the count is the number that tells them how much to cut.

Two of the four already do it. `main.tf:310` and `main.tf:314` say "is 26 chars;
Azure allows 3-24". Copy that wording to:

- `preflight.sh:609`, which prints no count at all. It relays Azure's generic rule
  text truncated at 110 characters, so the one number the operator needs is the
  one number missing.
- The Postgres and Redis precondition at `main.tf:317`, which names both limits and
  neither length, and covers two resources in one condition so the message cannot
  say which name is the long one. Split it into two preconditions and print each
  count.

The wizard's own check from issue 11 should follow the same wording, so the
operator sees the same sentence wherever the failure catches them.

## 13. `make setup-env` re-asks everything on every run

`setup-env.sh:198` collects three values: the Postgres password, the license key,
and the admin email. Only the first is resolved from a durable source, `_kv_secret`
reading Key Vault then `.pg_password`. The license key and the admin email are
retyped from scratch every run, even though the previous run wrote both to
`secrets.auto.tfvars` at chmod 600 (`setup-env.sh:220`), and even though Terraform
puts the license key in Key Vault as `langsmith-license-key`
(`keyvault/main.tf:165`) where the same read would find it. `Makefile:61`
advertises "prompts on first run, reads KV on repeat", which is true for one value
of three.

There is also no retry. A blank or mistyped license key makes `_prompt` return 1
(`setup-env.sh:77`), and under `set -euo pipefail` the assignment takes the script
down with it. Nothing typed so far survives, because the file is not written until
line 216, and `make plan` / `make apply` only re-run the script when the file is
absent (`Makefile:74`), so the next target restarts the full interview. A license
key is a long opaque paste, which makes it both the most likely value to go wrong
and the most annoying to retype.

Fix: read the existing `secrets.auto.tfvars` at startup and offer each value as
the default, "Enter = keep current", masking the license key to its last four
characters and showing the email in full. The wizard already has this exact
prefill for `terraform.tfvars` (`quickstart.sh:186`, whose comment says a re-run
should edit the existing config instead of retyping it), so the pattern is
established; `_parse_tfvar` in `_common.sh:32` hardcodes `terraform.tfvars` and
needs a file argument to be reusable here. Then fall back to Key Vault for the
license key the way the Postgres password already does, and re-ask on a blank
answer rather than exiting. The env-var path (`LANGSMITH_LICENSE_KEY=...`) covers
scripted re-runs today and does nothing for an operator at a prompt.

## 14. Nothing anticipates a 403 on a read, and the PIM check cannot see expiry

From a live `make plan` against an already-applied deployment, same object ID as
issue 9:

```
Error: retrieving Public IP Address ... unexpected status 403 (403 Forbidden)
  ... does not have authorization to perform action
  'Microsoft.Network/publicIPAddresses/read' over scope ...
Error: reading resource group: ... 'Microsoft.Resources/subscriptions/resourceGroups/read'
```

Refresh needs read on everything already in state, and preflight probes nine
actions that are all writes (`preflight.sh:220`). So its RBAC section says nothing
about the permission that plan actually exercises first, and every 403 remediation
we ship is about role assignments: `TROUBLESHOOTING.md:213`, `:326`, `:374` and
`PERMISSIONS.md:75`. An operator who searches the message they got lands in a
section about a different action.

The likely cause here is a PIM activation that lapsed between the passing preflight
and this plan, which our tooling cannot report either way. `preflight.sh:256`
queries `roleEligibilityScheduleInstances`, the eligible-but-inactive list.
`roleAssignmentScheduleInstances` is the sibling call that returns active
activations with their `endDateTime`, and nothing reads it. A first apply of AKS
plus Postgres runs well past a short activation window, so "activated, and it
expires in 20 minutes" is a distinct blocker from "not activated" and reads
identically today: silence.

Fix: add `Microsoft.Resources/subscriptions/resourceGroups/read` to the probe list,
which is free because checkAccess batches, and catches a lapsed window at the top
of the run. Query `roleAssignmentScheduleInstances?$filter=asTarget()` and print
the time left on any active PIM assignment, warning when it is under roughly 45
minutes. Add a TROUBLESHOOTING entry keyed on the read wording, since Azure's own
"if access was recently granted, please refresh your credentials" points an
operator at re-login when the answer is usually reactivation.

## 15. Nothing summarizes the plan, and the wizard never sends you to one

The wizard's next steps go from `make preflight` straight to
`make init && make apply` (`quickstart.sh:1988`). `make plan` is not one of the six
steps, and `make apply` runs `-auto-approve` across three targeted stages
(`Makefile:80`), so the default path applies a first deployment without the
operator ever seeing what it will build.

An operator who does look gets raw plan output: refresh lines for everything in
state, then several hundred lines of attributes, with `Plan: N to add...` at the
bottom. Nothing groups it by module or says "one AKS cluster, one Postgres server,
eight role assignments".

The plan-file path has its own trap. Saving one requires
`make plan ARGS="-out=plan.out"` (`Makefile:31`); typed the natural way,
`make plan -out=plan0812026-1`, make swallows the flag as its own `-o` and runs a
plain plan, so terraform never writes the file and nothing says the request was
dropped. `modules/azure/.gitignore:16` also ignores exactly `plan.out`, so any
other filename is a plan file sitting in the working tree waiting to be committed.

Fix: have `make plan` always write `infra/plan.out`, the name already gitignored,
and print a summary after it — counts by action, then one line per resource grouped
by module — followed by the two commands worth knowing: `make show` for the full
detail and `make tf ARGS="apply plan.out"` to apply exactly what was summarized.
`terraform show -json plan.out` plus python3 covers it, and python3 is already a
dependency of preflight, so no jq requirement. Then add plan as a step in the
wizard's next steps, since a readable summary is the review gate `-auto-approve`
takes away. At the far end, after deploy, point at the friendly views of what was
built: `make status` and an outputs view, which today is only findable in
`make help`.
