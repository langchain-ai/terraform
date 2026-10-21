# Azure PR test-and-merge prompts

One prompt per PR, in merge order. Each is self-contained — open a fresh thread, paste
the block, work it to a merge.

Order and rationale live in the table at the bottom. The short version: #120 leads because it
needs no fixture at all and every other thread pins the floor it declares. #115 renames
resources, so it has to define the naming scheme before any upgrade-in-place test
(#113, #109, #106, #116) can mean anything. Stand up **one** environment on #115 and
keep it alive through #116, the last thread that attaches to it.

Five rules run through every prompt.

**Terraform 1.11.0, pinned per worktree.** PR #120 declares that floor and lands first, so
from slot 1 onward the version every thread pins is the version the tree declares. It is also
the oldest CLI a consumer can run. The machine default is 1.14.6, which would let a module use
a 1.12+ feature while claiming 1.11. Pin it before the first `terraform init` in the
worktree. This is a floor-validation rule, not a state constraint: a 1.11.0 CLI reads state
written by 1.14.6 without complaint.

**Everything stacks on `test/azure-stack`.** None of the ten PRs below are merged, so no
thread branches from `main`. `test/azure-stack` is a local integration branch holding
`origin/main` plus every PR in this sequence that has already passed, merged in order. Each
thread branches from it, merges its own PR branch in, and tests the result. When a PR passes
I move `test/azure-stack` forward, so the next thread inherits the conflict resolution instead
of redoing it. From #115 onward this is mandatory: the threads share one Terraform state, and a
tree missing #115's renames would plan a full destroy-and-recreate against the live
deployment. Nothing here gets pushed.

**The base carries chart 0.16.** `origin/main` finished the cutover: the pinned line is
`~0.16.0`, module values moved to the 0.16 schema, and `v0.16.0` through `v0.16.2` are tagged.
Every `make deploy` below therefore exercises 0.16, and each of these PRs that merges auto-cuts
another `v0.16.x`.

**Real subscription, real resources.** Every test authenticates against the Langchain
subscription and creates something, even the prompts that look like pure validation work.
A plan that never reaches ARM proves nothing about a value that has to survive an API call.

**A short test log posted as a PR comment on success.** A numbered list, one line per step,
what was run and what was observed. Nothing else: no summary, no caveats section, no notes,
no description of what the change does. The reviewer already knows.

---

## 1. PR #120 — Terraform 1.11 floor

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #120, branch chore/bump-terraform-1.11.2

Do not push anything and do not merge the PR without asking me first.

This one goes first and needs no deployment. It is a 13-file string change —
required_version in modules/{aws,gcp}/app/versions.tf and modules/azure/{infra,app}/versions.tf
plus nine doc references — and it declares the floor every other thread in this sequence
already pins. required_version is a CLI gate that appears in no resource schema, so it cannot
change a plan and there is nothing here to test against live infrastructure. It also gates
#116, which is currently built on a 1.7 floor with a seed script because write-only arguments
need 1.11; landing this first lets that thread choose the better shape.

Terraform: this PR is the one place the version is the subject rather than the setting, so
you need three of them. Use mise: 1.11.0 (the declared floor, must pass), 1.14.6 (newest,
must also pass), and 1.10.5 (below the floor, must refuse). Start on 1.11.0.

Naming: the branch says 1.11.2 but every versions.tf declares >= 1.11.0. 1.11.0 is correct,
since write-only arguments landed in 1.11.0, so fix the PR title rather than the code.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` if you authenticate at all. Nothing in this PR creates or touches a
resource, and no step below needs credentials.

State: do not write modules/azure/infra/backend_override.tf and do not point any of the three
CLIs at remote state. Every step is init and validate against local files. The shared key
terraform/state/langsmith-devfreddy belongs to the #115 deployment that comes later in the
sequence — three CLI versions pointed at one live blob is exactly the accident to avoid.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. It was
rebuilt onto current origin/main after #94 merged upstream, so it now holds exactly two
merges, #97 and #105. #94 passed too, but its fix reaches you from main rather than from the
stack. Confirm with `git log --oneline --merges origin/main..test/azure-stack` before you
start — that lists the stack's own merges and nothing upstream, so you should see those two
and nothing else — and tell me if it does not match. Set up with:

  git worktree add .claude/worktrees/pr120-stack -b test/pr120-on-stack test/azure-stack
  cd .claude/worktrees/pr120-stack
  git merge origin/chore/bump-terraform-1.11.2

That merge is clean against the rebuilt stack — already verified with git merge-tree, so do
not re-derive it, and tell me if you get a conflict anyway. When the PR passes, stop and
report — I move test/azure-stack forward, and every later thread then inherits the floor from
its base instead of declaring it. Do not move the branch yourself and do not push any of these
branches.

Test:

1. required_version is a CLI floor, so the real risk is a module that only claims 1.11 and
   a user who is not on it. Confirm every module in the repo now declares a consistent
   floor and that no module declares a floor lower than a feature it actually uses.
2. On 1.11.0, run terraform init and validate on every changed module and confirm clean.
   This is the check that matters: passing on 1.14.6 says nothing about whether the code
   stays inside what 1.11.0 can parse. Repeat on 1.14.6 to confirm the ceiling is fine too.
3. Switch to 1.10.5 and confirm each bumped module refuses with a clear version error rather
   than a confusing parse failure.
4. Confirm the AWS module changes with init and validate only. There is local state at
   modules/aws/infra/terraform.tfstate stamped 1.14.6, but it holds zero resources and a
   1.11.0 CLI reads it without complaint, so it is not an obstacle and not something to
   "fix" by upgrading the CLI mid-run. Leave it alone.
5. Check whether OpenTofu is claimed as supported anywhere in the docs. If it is, the
   1.11 floor needs a corresponding statement about which OpenTofu release matches.

One conflict to know about, not to resolve here: #118 deletes all three app/versions.tf files,
which are three of this PR's four module bumps. Floor-first makes that trivial — #118's
deletion wins on rebase — so note it on the PR and leave it.

On success, post a comment on the PR: a matrix of module against the three CLI versions with
the result in each cell, then the 1.10.5 error verbatim in a code block. Nothing else. No
summary, no caveats, no notes, no description of the change. Then report to me and stop for
my review before merging.
````

---

## 2. PR #97 — setup-env.sh invisible prompts

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #97, branch fix/azure-setup-env-invisible-prompts

Work in a git worktree off that branch. Do not commit, push, or merge without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the floor the modules declare, so it is the
version to test on, not the 1.14.6 on PATH.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` before anything that writes. This one creates real resources: a Postgres
Flexible Server in step 3 and a Key Vault in step 7, both in throwaway resource groups you
destroy afterward. Check `az group list -o table` for a name nobody else is using.

Rebase onto current origin/main and report conflicts before proceeding.

The bug: prompt text went to stdout inside a function called as $(_prompt ...), so the
prompt was invisible and the captured secret was "prompt text + typed value".

Test — drive it over a real pty with expect, not by piping:

1. First run, no env vars set, against a throwaway infra dir. Prompts must render. Password
   fields stay hidden, the admin email echoes. Inspect the generated secrets.auto.tfvars
   and confirm no prompt text leaked into any value.
2. Leave the PostgreSQL prompt blank. Confirm a password is generated, that it satisfies
   Azure Flexible Server's 3-of-4 character-class rule, and that a second run returns the
   same value.
3. Take the generated Postgres password and actually create a real
   azurerm_postgresql_flexible_server with it in a throwaway resource group. This is the
   one thing worth spending real resources on here: the PR claims the `Ls1!` prefix
   round-trips through the hand-rolled replace(password, "!", "%21") in
   modules/postgres/outputs.tf. Confirm the connection URL the module emits actually
   connects, then destroy the RG.
4. Non-interactive with nothing preset: must exit 1 with the missing variables listed on
   stdout. Verify with stderr discarded — that is the sandboxed-shell case that reported
   nothing before.
5. Non-interactive with the three required vars set: completes, writes correct tfvars.
6. Blank required field: reports the missing variable instead of writing an empty secret.
7. Key Vault path: create a real RBAC vault in the Langchain subscription, write the secrets
   into it, then run setup-env a second time and confirm it reads back rather than prompting.
   Then run with egress to the vault blocked and confirm the timeout bound fires fast instead
   of stalling. Destroy the vault afterward, purge included.
8. Seed all seven fallback dot-files in a throwaway infra dir, run scripts/clean.sh,
   confirm all seven are gone including .pg_password.

Note for the merge: PR #116 later rewrites this same file and its version currently
reintroduces this exact bug. Leave a comment on #116 pointing at whatever the final
_prompt implementation here looks like.

On success, post a comment on the PR: Terraform version and subscription on one line, then a
numbered list, one line per step, what you ran and what you observed. Nothing else. No
summary, no caveats, no notes, no description of the change. Redact every secret value,
including generated passwords. Then report to me and stop for my review before merging.
````

---

## 3. PR #105 — preflight RBAC and offer-type probe

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #105, branch fix/azure-preflight-rbac-probe

Work in a git worktree off that branch. Do not commit, push, or merge without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the floor the modules declare, so it is the
version to test on, not the 1.14.6 on PATH.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show`. The preflight script itself is read-only, but this test is not: you create
a real service principal in step 5 and run a real apply as that principal in step 6. Delete
the SP and destroy the RG when done.

Rebase onto current origin/main and report conflicts before proceeding.

Test against the real subscription:

1. `make preflight` as yourself. Every one of the nine probed actions should come back
   allowed at subscription scope. Capture the full output.
2. Confirm the script reports which path produced the verdict — the checkAccess primary
   path or the degraded role-name fallback. A clean result on the fallback is a weaker
   result and the output has to say so. Force the fallback (block the endpoint or feed a
   reshaped response) and confirm it degrades rather than reporting a false pass.
3. Deployer Identity section: export ARM_SUBSCRIPTION_ID set to a different subscription
   than the active az login and confirm it hard-fails. Same for a mismatched ARM_TENANT_ID.
   This is the check that stops preflight validating one subscription while Terraform
   deploys into another.
4. Set ARM_CLIENT_ID to a service principal and confirm preflight resolves and probes that
   principal, not the az login user.
5. Create a real service principal with Contributor but NOT Role Based Access Control
   Administrator, at subscription scope. Probe it. roleAssignments/write must come back
   denied with an actionable message. That is the failure this PR exists to catch, and it
   is worth the five minutes to create the SP.
6. Prove the prediction is true and not just plausible: authenticate as that same restricted
   SP and run a real `terraform apply` into a throwaway resource group. It must fail on a
   role assignment, in the way preflight said it would. A preflight that predicts a denial
   Azure does not actually issue is worse than no preflight. Destroy the RG and delete the SP
   afterward.
7. If you can get an ABAC-conditioned or PIM-eligible grant in this tenant, probe that too.
   If you cannot, say so explicitly rather than claiming coverage.
8. Offer type: the Langchain subscription is almost certainly Pay-As-You-Go, so the restricted
   -offer warning will not fire naturally. Stub the quotaId response for each restricted
   family (FreeTrial, MSDN, VisualStudio, AzurePass, MPN, sponsored) and confirm each is
   matched by prefix.
9. Run scripts/test-preflight-rbac.py and report pass/fail counts.
10. Confirm postgres_sku_name now actually reaches the postgres module — `terraform plan`
    with a non-default SKU and check the planned server SKU changes.

On success, post a comment on the PR: Terraform version and subscription on one line, then a
numbered list, one line per step, what you ran and what you observed. Quote the step 6 apply
failure verbatim in a code block. Nothing else. No summary, no caveats, no notes, no
description of the change. Redact the SP's credentials and object ID. Then report to me and
stop for my review before merging.
````

---

## 4. PR #115 — wizard, unified naming, per-subnet BYO networking

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #115, branch feat/azure-wizard-and-byo-networking

This is the big one — 2617 lines consolidating five stacked PRs. Do not push anything and
do not merge the PR without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 BEFORE the first init. 1.11.0 is the floor the modules declare, so it is the
version under test. Every later thread stays on it too, so the sequence validates the floor
rather than whatever is newest on PATH.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` before anything that writes. Use eastus. Use a resource group name
nobody else is using — check `az group list -o table` first; there are already several
langsmith-* groups in this subscription that belong to other work. Do not touch them.

State: this matters more here than anywhere else in the set. `backend.tf` ships with the
backend commented out and `backend_override.tf` is gitignored, so a fresh worktree defaults
to local state inside the worktree. That is the wrong place — #124, #113, #109, #106, and
#116 each run from their own worktree and all need to reach this state, and pruning the
worktree would orphan the deployment. Before the first `terraform init`, write
modules/azure/infra/backend_override.tf in the worktree with exactly this:

  terraform {
    backend "azurerm" {
      resource_group_name  = "terraform-state-rg"
      storage_account_name = "langchainterraformstate"
      container_name       = "tfstate"
      key                  = "terraform/state/langsmith-devfreddy"
    }
  }

That key is mine and currently empty. Do not change the key line. The same container holds
terraform/state/langsmith-dev and terraform/state/azure-org, both live and shared — writing
to either destroys someone else's environment.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. By now
that should be #97, #105, #120. Confirm with
`git log --oneline --merges origin/main..test/azure-stack` before you start and tell me if it
does not match — #120 has to be in it, because the 1.11 floor this thread pins now arrives
from the base rather than from any commit you write. Set up with:

  git worktree add .claude/worktrees/pr115-stack -b test/pr115-on-stack test/azure-stack
  cd .claude/worktrees/pr115-stack
  git merge origin/feat/azure-wizard-and-byo-networking

#105 rewrote infra/scripts/preflight.sh and this branch adds ~134 lines to the same file, so
expect a conflict there. Resolve by hand and show me the resolution before applying anything.

If test/pr115-on-stack and its worktree already exist from an earlier run, they sit on the
pre-rebuild stack, which predates both the chart 0.16 cutover and #94 merging. Delete the
worktree and the branch and start from the command above rather than rebasing them.

Do not bump a Terraform floor of your own. The PR branch touches no versions.tf; an earlier run
of this thread wrote commit 1bb162c on test/pr115-on-stack raising
modules/azure/infra/versions.tf and three azure docs to 1.11.0, and all four hunks are
byte-identical to #120's. #120 is in the base, so the floor arrives from there and that commit
does not need writing again.

When the PR passes, stop and report — I move test/azure-stack forward so the next thread
inherits your resolution. Do not move it yourself and do not push any of these branches.

This PR renames resources — name_prefix replaces identifier/environment, and
unique_resource_names changes the name base. Both are destroy-and-recreate. So the
environment you build here is the one every later PR tests against. Build it to last:
keep the resource group, the state, and the tfvars, and tell me the RG name when you are
done so I can point the next threads at it.

Test:

1. `make preflight`, then `make quickstart` driven interactively for real. Take the
   greenfield path with unique_resource_names = true.
2. Wizard resume: kill the wizard partway, re-run, confirm it resumes at the right step
   with prior answers intact. Do this at three different steps including one after the
   subnet questions. Then run scripts/test-quickstart-state.sh and report the count.
3. Back-navigation: walk backward through the wizard and confirm changing an earlier
   answer invalidates the dependent later ones rather than keeping stale values.
4. Migration guard: put a non-empty `identifier` in terraform.tfvars and confirm the plan
   fails with the explanation. Then confirm _load_tfvars still accepts the retired
   identifier key on resume without crashing.
5. Full `make apply` on the greenfield config. This is the long pole. Capture the plan
   before applying and confirm no unexpected replaces.
6. Verify the deployed resource names actually carry the per-subscription hash that
   unique_resource_names promises, and that Postgres, Redis, Blob, and Key Vault names are
   all globally unique in practice — not just that Terraform planned them.
7. Per-subnet BYO: you need a separate VNet with aks/postgres/redis subnets shaped the way
   modules/azure/test/existing-aks-cluster (on branch origin/test/azure-e2e) does it.
   Resource group mf-byo-e2e-rg in eastus2 already holds that fixture from earlier work —
   check whether it still matches what the fixture builds and reuse it if so, rather than
   standing up a second one. Then apply a second deployment with create_vnet = false and
   only SOME subnet IDs supplied. The whole point of this change is that BYO subnets are
   optional per subnet, so test the mixed case, not just all-or-nothing.
8. manage_byo_subnet_service_endpoints: confirm both settings. Known trap from earlier
   work — azapi leaves service endpoints behind on destroy, and clearing them needs
   --set serviceEndpoints='[]'.
9. AGIC: this has never been through a live apply. Set ingress_controller = "agic", apply,
   and confirm the App Gateway comes up, the three AGIC role assignments land, the
   NetworkPolicy objects are created, and an ingress actually routes traffic. If it fails,
   that is the finding — report it rather than working around it.
10. Deploy the chart on top (`make kubeconfig`, `make k8s-secrets`, `make init-values`,
    `make deploy`) and confirm LangSmith actually comes up. Infra that applies clean but
    does not run the product is not a pass.
11. Tear down only the throwaway BYO-network deployment from step 7 and the AGIC
    deployment from step 9. Leave the main greenfield deployment running.

On success, post a comment on the PR: Terraform version, subscription, and region on one
line, then a numbered list, one line per step, what you ran and what you observed. Nothing
else. No summary, no caveats, no notes, no description of the change. Redact secrets and the
deployment's hostnames. Then report to me separately, not in the comment: the RG name,
confirmation that the state landed at the key above and not on disk, and the tfvars you
used. Stop for my review before merging.
````

---

## 5. PR #124 — honor clickhouse_source = "external"

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #124, branch claude/clickhouse-zones-variable-9be982

Do not push anything and do not merge the PR without asking me first.

Prerequisite: do not start until I have told you #115 passed and that I have advanced
test/azure-stack to include it. This thread deploys against the cluster #115 builds, and its
base branch has to carry #115's renames. If you have this prompt before that, stop and ask me.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the declared floor and the version the whole
sequence is validating.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show`. This PR touches only modules/azure/helm/scripts — no Terraform — but it
deploys for real against the live #115 cluster. Get the resource group and cluster from the
remote state rather than asking me: with the backend override below in place, run
`terraform init` in modules/azure/infra, then `terraform output resource_group_name` and
`terraform output -raw get_credentials_command`. Run that credentials command, then confirm
`kubectl config current-context` matches `terraform output aks_cluster_name` before any
kubectl or helm command.

State: the scripts here read `terraform output` against the #115 deployment, whose state is
remote. Before the first `terraform init`, write modules/azure/infra/backend_override.tf in
the worktree with exactly this:

  terraform {
    backend "azurerm" {
      resource_group_name  = "terraform-state-rg"
      storage_account_name = "langchainterraformstate"
      container_name       = "tfstate"
      key                  = "terraform/state/langsmith-devfreddy"
    }
  }

That file is gitignored, so a fresh worktree will not have it and will silently fall back to
empty local state. Do not change the key line. The same container holds
terraform/state/langsmith-dev and terraform/state/azure-org, both live and shared.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. By now
that should be #97, #105, #120, #115. Confirm with
`git log --oneline --merges origin/main..test/azure-stack` before you start and tell me if it
does not match — #115 has to be in it, because this thread plans against the state #115 built
and a tree without #115's renames would plan a full destroy-and-recreate. Set up with:

  git worktree add .claude/worktrees/pr124-stack -b test/pr124-on-stack test/azure-stack
  cd .claude/worktrees/pr124-stack
  git merge origin/claude/clickhouse-zones-variable-9be982

Expect one conflict, in modules/azure/README.md, verified with git merge-tree against the
current stack. helm/scripts/init-values.sh auto-merges, but do not take that on faith: main's
chart 0.16 migration (commit c71635e) rewrote the insights block in that same file. Read the
merged script end to end before you run it. The bug is still there on main after that rewrite
— init-values.sh re-parses clickhouse_source inside `if [[ "$_enable_insights" == "true" ]]`,
which is the gate this PR removes — so the fix is still the right one. Resolve by hand and
show me before applying anything. When the PR passes, stop and report — I move
test/azure-stack forward so the next thread inherits your resolution. Do not move it yourself
and do not push any of these branches.

The bug: init-values.sh only read clickhouse_source inside the enable_insights branch, so
with insights off the chart deployed its own ClickHouse StatefulSet while Terraform
reported external. Traces silently went to the wrong store.

Test on the real cluster:

1. The case that was broken: clickhouse_source = "external" with insights OFF. Run
   init-values.sh, inspect the generated values-overrides.yaml, then actually
   `make deploy`. Confirm there is no <release>-langsmith-clickhouse StatefulSet, Service,
   ConfigMap, Secret, or ServiceAccount in the namespace.
2. Point it at a real external ClickHouse. Stand one up if you have to — LangChain Managed
   ClickHouse, an Altinity instance, or a plain ClickHouse container reachable from the
   cluster. Send real traces through LangSmith and confirm they land in the external
   instance and nowhere else. This is the whole point of the PR and a values-file diff does
   not prove it.
3. Seven-key secret contract: confirm the secret init-values.sh creates has all seven keys
   (clickhouse_host, port, native_port, user, password, db, tls) and that the chart's
   secretKeyRef with optional:false resolves every one. The chart is 0.16 here, not the
   0.15 line this PR was written against — if 0.16 renamed or added a key, that is a
   finding for the PR rather than something to work around. Delete one key and confirm pods go
   to CreateContainerConfigError, which is the failure the old example file caused.
4. deploy.sh must refuse to deploy when a key is missing and name the missing ones. Test it.
5. Password handling: capture argv while kubectl runs and confirm the password is absent
   (it should go through a mktemp 0600 file via --from-file). Confirm the temp file is 0600
   and is cleaned up.
6. Unreachable cluster: point KUBECONFIG at nothing and confirm init-values.sh warns,
   skips the secret prompt, exits 0, and still writes all values files.
7. In-cluster mode: confirm no prompt, no secret, and the chart's own ClickHouse comes back.
8. Re-run against a namespace where the secret already exists and confirm it is left as-is.

Restore the cluster to in-cluster ClickHouse when done so the next thread inherits a known
state.

On success, post a comment on the PR: Terraform version and subscription on one line, then a
numbered list, one line per step, what you ran and what you observed. Step 2's line must say
how you confirmed the traces landed in the external instance. Nothing else. No summary, no
caveats, no notes, no description of the change. Redact connection strings, hostnames, and
credentials. Then report to me and stop for my review before merging.
````

---

## 6. PR #113 — fail loudly on AKS zone drift

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #113, branch fix/azure-aks-zone-drift

Do not push anything and do not merge the PR without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the declared floor and the version the whole
sequence is validating, including this apply against the #115 deployment.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show`. Applies for real against the live AKS cluster from PR #115 — ask me for
the resource group if you do not have it. Creates nothing new.

State: the #115 deployment's state is remote. Before the first `terraform init`, write
modules/azure/infra/backend_override.tf in the worktree with exactly this:

  terraform {
    backend "azurerm" {
      resource_group_name  = "terraform-state-rg"
      storage_account_name = "langchainterraformstate"
      container_name       = "tfstate"
      key                  = "terraform/state/langsmith-devfreddy"
    }
  }

That file is gitignored, so a fresh worktree will not have it and will silently fall back to
empty local state — which would look like a greenfield plan against a live cluster. Do not
change the key line. The same container holds terraform/state/langsmith-dev and
terraform/state/azure-org, both live and shared.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. By now
that should be #97, #105, #120, #115, #124. Confirm with
`git log --oneline --merges origin/main..test/azure-stack` before you start and tell me if it
does not match — #115 has to be in it, because this thread plans against the state #115 built
and a tree without #115's renames would plan a full destroy-and-recreate. Set up with:

  git worktree add .claude/worktrees/pr113-stack -b test/pr113-on-stack test/azure-stack
  cd .claude/worktrees/pr113-stack
  git merge origin/fix/azure-aks-zone-drift

Conflicts expected on modules/azure/infra/main.tf and README.md. Resolve by hand and show me
before applying. When the PR passes, stop and report — I move test/azure-stack forward so the
next thread inherits your resolution. Do not move it yourself and do not push any of these
branches.

The change: azurerm_kubernetes_cluster ignores changes to default_node_pool[0].zones, so
editing availability_zones on a live cluster plans clean, applies clean, and does nothing.
This adds a postcondition that names both the requested and actual zone sets.

Test against the live cluster:

1. Apply with availability_zones matching what the cluster actually runs. Must pass clean
   with no diff. Confirm with `az aks nodepool show --query availabilityZones`.
2. Change availability_zones to a different set and apply. The postcondition must fire and
   the message must name both sets. Capture the exact error text — the value of this PR is
   entirely in whether that message tells an operator what to do.
3. The behavior reviewers need to know about: on a cluster already in a drifted state this
   fires on the NEXT apply, including one that has nothing to do with zones. Reproduce
   that. Put the cluster in a drifted state, then run an apply that changes something
   unrelated, and confirm it fails. Decide whether that is acceptable and say so.
4. Confirm the documented remedy actually works: revert availability_zones to match, apply,
   clean.
5. Confirm removing the unused availability_zones input from the networking module produces
   no plan diff and no state change. `terraform plan` before and after must be identical.
6. `terraform fmt -check -recursive modules/azure/` and `terraform validate` clean.

Leave the cluster in a non-drifted state.

On success, post a comment on the PR: Terraform version and subscription on one line, then a
numbered list, one line per step, what you ran and what you observed. Quote the step 2 error
text verbatim in a code block. Nothing else. No summary, no caveats, no notes, no description
of the change. Redact the cluster name and resource group. Your call on the step 3 behavior
goes to me, not the comment. Then stop for my review before merging.
````

---

## 7. PR #109 — AMR Balanced_B1 default, Redis HA

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #109, branch fix/azure-amr-sku-defaults

Do not push anything and do not merge the PR without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the declared floor and the version the whole
sequence is validating, including steps 1 through 4 against the #115 deployment.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` before anything that writes. This one changes a live Redis instance in
place and stands up a second one in another region.

State: steps 1 through 4 run against the #115 deployment, whose state is remote. Before the
first `terraform init`, write modules/azure/infra/backend_override.tf in the worktree with
exactly this:

  terraform {
    backend "azurerm" {
      resource_group_name  = "terraform-state-rg"
      storage_account_name = "langchainterraformstate"
      container_name       = "tfstate"
      key                  = "terraform/state/langsmith-devfreddy"
    }
  }

That file is gitignored, so a fresh worktree will not have it and will silently fall back to
empty local state — which would look like a greenfield plan against a live deployment. Do
not change the key line. The same container holds terraform/state/langsmith-dev and
terraform/state/azure-org, both live and shared. The westus2 production-profile run in
steps 5 and 6 is throwaway, so give it local state or its own key, never this one.

REGION WARNING: Azure Managed Redis Balanced_B3 and B5 both return InsufficientCapacity in
eastus — that is a confirmed regional shortage, not a sizing problem. Test the production
profile in westus2 or centralus. Check capacity before you start rather than discovering it
mid-apply.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. By now
that should be #97, #105, #120, #115, #124, #113. Confirm with
`git log --oneline --merges origin/main..test/azure-stack` before you start and tell me if it
does not match — #115 has to be in it, because this thread plans against the state #115 built
and a tree without #115's renames would plan a full destroy-and-recreate. Set up with:

  git worktree add .claude/worktrees/pr109-stack -b test/pr109-on-stack test/azure-stack
  cd .claude/worktrees/pr109-stack
  git merge origin/fix/azure-amr-sku-defaults

Conflicts expected on scripts/quickstart.sh, terraform.tfvars.dev, and
terraform.tfvars.production. Resolve by hand and show me before applying. When the PR passes,
stop and report — I move test/azure-stack forward so the next thread inherits your
resolution. Do not move it yourself and do not push any of these branches.

Note: the PR description is stale. It claims to raise the Terraform floor to 1.9 for a
cross-variable validation. Commit c9bb6bb reverted that and moved the check to a
precondition; the branch is at >= 1.5. Fix the description as part of this work.

Test:

1. In-place SKU change on a live instance. Take the existing AMR from the #115 deployment
   (currently on the old default) and apply this branch. The plan must show an in-place
   body update, NOT destroy-and-recreate. If it shows a replace, that is a data-loss
   finding and the PR's upgrade-impact claim is wrong. Capture the plan.
2. Confirm the instance is actually Balanced_B1 afterward via `az redisenterprise show`
   or the azapi read, not just that Terraform said so.
3. Enable HA in place on that same live instance. The PR explicitly says this has not been
   exercised against a live cluster — that is the gap this thread closes. Confirm the plan
   is in-place, apply it, and verify the replica exists.
4. Confirm LangSmith still connects after the HA change. Restart the pods and check they
   reach Redis.
5. The B0+HA precondition: set amr_sku = "Balanced_B0" with redis_high_availability = true
   and confirm the plan fails. Then confirm B0+false and B3+true both pass. Do the B3 run
   in westus2.
6. Production profile: apply terraform.tfvars.production in westus2 end to end and confirm
   Balanced_B3 + HA actually provisions. Destroy it after.
7. redis_capacity was dead in three places. Grep every tfvars template and the
   quickstart-generated output and confirm it is gone. Then cross-check every remaining
   assignment in all four templates against the declared variable list — Terraform silently
   ignores undeclared variables, so anything else dead will not error either.

On success, post a comment on the PR: Terraform version, subscription, and the regions used
on one line, then a numbered list, one line per step, what you ran and what you observed.
Include the step 1 plan excerpt showing in-place rather than replace, in a code block.
Nothing else. No summary, no caveats, no notes, no description of the change. Redact the
Redis hostname and access keys. Then report to me and stop for my review before merging.
````

---

## 8. PR #106 — principal_type on managed-identity role assignments

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #106, branch fix/azure-role-assignment-principal-type

Do not push anything and do not merge the PR without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the declared floor and the version the whole
sequence is validating, including step 1 against the #115 deployment.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` before anything that writes. Applies against the live deployment from
PR #115 — ask me for the resource group — plus a throwaway RG and a real service principal
in steps 3 and 4.

State: step 1 runs against the #115 deployment, whose state is remote. Before the first
`terraform init`, write modules/azure/infra/backend_override.tf in the worktree with exactly
this:

  terraform {
    backend "azurerm" {
      resource_group_name  = "terraform-state-rg"
      storage_account_name = "langchainterraformstate"
      container_name       = "tfstate"
      key                  = "terraform/state/langsmith-devfreddy"
    }
  }

That file is gitignored, so a fresh worktree will not have it and will silently fall back to
empty local state — which would look like a greenfield plan against a live deployment, and
step 1's whole claim is about what happens to existing state rows. Do not change the key
line. The same container holds terraform/state/langsmith-dev and terraform/state/azure-org,
both live and shared. The throwaway RG in step 3 is throwaway, so give it local state or
its own key, never this one.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. By now
that should be #97, #105, #120, #115, #124, #113, #109. Confirm with
`git log --oneline --merges origin/main..test/azure-stack` before you start and tell me if it
does not match — #115 has to be in it, because step 1's whole claim is about what happens to
the state rows #115 created. Set up with:

  git worktree add .claude/worktrees/pr106-stack -b test/pr106-on-stack test/azure-stack
  cd .claude/worktrees/pr106-stack
  git merge origin/fix/azure-role-assignment-principal-type

Conflicts expected on BUILDING_LIGHT_LANGSMITH.md and, from #105, README.md. Resolve and show
me. When the PR passes, stop and report — I move test/azure-stack forward so the next thread
inherits your resolution. Do not move it yourself and do not push any of these branches.

principal_type is ForceNew. The PR's central claim is that defaulting it to null leaves
existing state rows alone so nothing gets replaced. That claim can only be tested against
existing state, which is what the #115 deployment gives you.

Test:

1. Apply this branch against the existing deployment. The plan must show 0 to destroy and
   0 to replace across all seven role assignments. If any assignment queues a
   destroy-and-recreate, stop and report it — that is a live-deployment breakage.
2. Confirm the seven hardcoded ServicePrincipal assignments are the right seven and that
   each target really is a managed identity, not an operator-supplied principal:
   storage/blob_data_contributor, keyvault/managed_identity_kv_reader, dns/cert_manager_dns,
   bastion/vm_admin_login, and the three AGIC assignments in k8s-cluster.
3. Fresh apply into a throwaway resource group with principal_type set. Confirm the
   assignments are created with the declared type — read it back with
   `az role assignment list --query "[].principalType"`, do not trust the plan.
4. terraform_principal_type toggle: run once with "User" under an interactive az login and
   once with "ServicePrincipal" as a real SP you create in this subscription. Both must
   produce a working keyvault.terraform_kv_admin grant that can actually read and write
   secrets. Prove the data-plane access against the real vault, not just the assignment's
   existence. Delete the SP afterward.
5. Confirm the default of null still omits the field entirely from the create payload.
   Check with `az rest` or provider trace logging, not by inference.
6. Validation: confirm null plus User, Group, ServicePrincipal are accepted and that ""
   is rejected with a message that steers toward omitting the variable.
7. AGIC assignments now read local.agic_addon_principal_id instead of inlining the
   expression. Confirm the object ID is identical to before — compare the assignment's
   principalId in Azure against what the previous code produced.
8. If you can construct an ABAC condition on principalType in this tenant, apply against it
   and confirm the assignments now succeed where they previously 403'd. If you cannot, say
   so explicitly — that is the exact scenario this PR exists for and it would be untested.

Destroy the throwaway RG from step 3 and delete the SP from step 4. Leave the #115
deployment running.

On success, post a comment on the PR: Terraform version and subscription on one line, then a
numbered list, one line per step, what you ran and what you observed. Include the step 1 plan
summary showing 0 replaced. If step 8 could not be run, its line says so in four words.
Nothing else. No summary, no caveats, no notes, no description of the change. Redact object
IDs and credentials. Then report to me and stop for my review before merging.
````

---

## 9. PR #95 — deploy onto an existing AKS cluster and Key Vault

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #95, branch feat/azure-byoc-existing-cluster

Do not push anything and do not merge the PR without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. That includes the fixture. Build it on the same version
as the module that attaches to it.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` before anything that writes. Use eastus. This one needs its own fixture
and its own resource group — do not point it at the #115 deployment. Check
`az group list -o table` for a free name.

State: local, which is what a fresh worktree gives you. Do not create
modules/azure/infra/backend_override.tf here and do not copy one in from another checkout.
Everything in this thread gets destroyed at the end, and the shared remote key belongs to
the #115 deployment.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. By now
that should be #97, #105, #120, #115, #124, #113, #109, #106. Confirm with
`git log --oneline --merges origin/main..test/azure-stack` before you start and tell me if it
does not match. Set up with:

  git worktree add .claude/worktrees/pr95-stack -b test/pr95-on-stack test/azure-stack
  cd .claude/worktrees/pr95-stack
  git merge origin/feat/azure-byoc-existing-cluster

This is the heaviest merge in the set: conflicts on infra/main.tf,
modules/k8s-cluster/main.tf, modules/keyvault/main.tf and variables.tf, infra/variables.tf,
scripts/setup-env.sh, and README.md. Resolve by hand, show me the resolution, and re-run
terraform validate before you apply anything. When the PR passes, stop and report — I move
test/azure-stack forward so the next thread inherits your resolution. Do not move it yourself
and do not push any of these branches.

Fixture: modules/azure/test/existing-aks-cluster/ exists on branch origin/test/azure-e2e
but not on this branch. Pull it in. It stands up the cluster and network a customer would
already own — VNet at 10.42.0.0/16, an aks-nodes /22, a delegated postgres subnet, a redis
subnet with PE policies off, and an AKS cluster with OIDC issuer and workload identity on.
Read its README first; every row in its table exists because something failed mid-apply
without it.

Test the happy path first, then break each guardrail deliberately:

1. Stand up the fixture. Then apply the module with create_cluster = false, create_vnet =
   false, and the fixture's outputs wired in. Deploy the chart on top and confirm LangSmith
   actually runs — pods authenticate to Blob and Key Vault via workload identity, traces
   write, the UI loads. Attaching to a cluster is worthless if the federated credentials
   point at nothing.
2. create_keyvault = false against a pre-existing RBAC vault. Confirm all nine secrets get
   written into it and that nothing else about the vault is reconfigured. Diff the vault's
   properties before and after.
3. Mixed case, which the PR calls the common one: create_cluster = false with
   create_keyvault = true. Confirm it works.
4. Now the guardrails. Each of these applied cleanly and failed at runtime before this PR,
   so each needs to fail at PLAN time now. Trigger every one against real Azure state:
   - ingress_controller = "agic" and "istio-addon" with create_cluster = false
   - a cluster with the OIDC issuer disabled (turn it off on a scratch cluster)
   - issuer on but workload identity off — these are separate AKS flags and this is the
     combination that passes the OIDC check and still leaves pods without a token
   - aks_subnet_id pointing at a subnet the cluster runs no nodes in
   - existing_cluster_name unset
   - create_keyvault = false with existing_keyvault_name or its resource group unset
   - an attached vault using access policies instead of Azure RBAC. This is the postcondition
     that matters most: azurerm_role_assignment against an access-policy vault grants nothing
     while the apply reports success. Create an access-policy vault and confirm it fails at
     plan rather than 403ing at runtime.
   For each, capture the actual error message and judge whether an operator could act on it.
5. location mismatch is a check block, not a precondition — confirm it warns and lets the
   apply proceed.
6. keyvault_manage_terraform_admin_assignment and keyvault_manage_managed_identity_assignment
   are gated independently. Confirm each can be turned off alone and that the deployment
   still works when the customer's platform team owns that grant.
7. existing_cluster_node_pools_managed = false: confirm the module adds no node pools and
   does not fight the platform team's.
8. Confirm the ignored-on-attach variables really are ignored: set keyvault_default_action,
   keyvault_allowed_ips, and keyvault_purge_protection while attached and confirm the vault
   is untouched.

Destroy the fixture and every scratch cluster and vault when done, purging the vaults.

On success, post a comment on the PR: Terraform version, subscription, and region on one
line, then a numbered list, one line per step, what you ran and what you observed. Step 4 is
a two-column table instead: guardrail, and the error message it now produces. Nothing else.
No summary, no caveats, no notes, no description of the change. Redact cluster names, vault
names, and hostnames. Your judgment on whether each message is actionable goes to me, not the
comment. Then stop for my review before merging.
````

---

## 10. PR #116 — keep LangSmith app secrets out of Terraform state

````text
Repo: /Users/michaelfrederick/Documents/Github/langchain-ai/terraform
PR: #116, branch fix/azure-secrets-out-of-tf-state

Do not push anything and do not merge the PR without asking me first.

Terraform: run `mise use terraform@1.11.0` in the worktree and confirm `terraform version`
reports 1.11.0 before anything else. 1.11.0 is the floor #120 landed and the version that
makes write-only arguments available, which is directly relevant to question (a) below. If
you take the write-only route, 1.11.0 is what has to support it, not 1.14.6.

Azure: subscription "Langchain" (014c3098-b01f-4585-a922-c5617c204ec2). Confirm with
`az account show` before anything that writes. Applies for real against the live deployment
from PR #115, which by now has the seven azurerm_key_vault_secret rows in state. Ask me for
the resource group. Step 8 stands up a second throwaway deployment you destroy afterward.

State: this PR is about what is in the state file, so getting the right one matters more
than usual. The #115 deployment's state is remote. Before the first `terraform init`, write
modules/azure/infra/backend_override.tf in the worktree with exactly this:

  terraform {
    backend "azurerm" {
      resource_group_name  = "terraform-state-rg"
      storage_account_name = "langchainterraformstate"
      container_name       = "tfstate"
      key                  = "terraform/state/langsmith-devfreddy"
    }
  }

That file is gitignored, so a fresh worktree will not have it and will silently fall back to
empty local state — and an empty state would make steps 1 and 9 pass vacuously. Do not
change the key line. The same container holds terraform/state/langsmith-dev and
terraform/state/azure-org, both live and shared. Step 8's throwaway deployment gets local
state or its own key, never this one. For step 9, pull the state with
`terraform state pull` rather than grepping a local file that will not exist.

DECIDE THE APPROACH FIRST, before any testing. Two open questions:

(a) This PR as written uses a seed script plus removed.tf at a 1.7 floor. PR #120 has since
    landed the 1.11 floor, which makes Terraform write-only arguments available. Write-only
    args keep the value out of state without a separate post-apply script and without the
    two-phase make setup-env -> make apply -> make seed-secrets -> make k8s-secrets flow.
    Evaluate both and tell me which you recommend and why before you build anything.
(b) modules/azure/app is a second plaintext sink for these same values and this PR does not
    touch it. If PR #118 (remove the app module) has landed, that resolves itself. If not,
    say what it would take.

Base: branch from the local integration branch test/azure-stack, not from main. None of the
ten PRs in this sequence are merged yet, so main does not carry them. test/azure-stack is
origin/main plus every PR in this sequence that has already passed, merged in order. This is
the last one, so by now that should be #97, #105, #120, #115, #124, #113, #109, #106, #95.
Confirm with `git log --oneline --merges origin/main..test/azure-stack` before you start and
tell me if it
does not match — #115 has to be in it, because steps 1 and 9 run against the state #115
built. Set up with:

  git worktree add .claude/worktrees/pr116-stack -b test/pr116-on-stack test/azure-stack
  cd .claude/worktrees/pr116-stack
  git merge origin/fix/azure-secrets-out-of-tf-state

Conflicts land in modules/azure/infra/variables.tf, BUILDING_LIGHT_LANGSMITH.md, and
infra/scripts/setup-env.sh against the current stack, and more will arrive with the PRs ahead
of you. Resolve by hand and show me before applying anything. When the PR passes, stop and
report. Do not move test/azure-stack yourself and do not push any of these branches.

The floor hunk gets dropped, not resolved. This branch bumps modules/azure/infra/versions.tf
from >= 1.5 to >= 1.7 to support the removed blocks in
modules/azure/infra/modules/keyvault/removed.tf. #120 is in the base at >= 1.11.0, which
already satisfies `removed`, so drop this branch's versions.tf hunk outright. Resolving it the
other way walks azure back to 1.7 with nothing in CI to catch it.

The setup-env.sh conflict needs specific attention: this branch's
infra/scripts/setup-env.sh reintroduces the bug PR #97 fixed. Line ~47 does
`printf "%s: " "$prompt_text"` on stdout inside _prompt(), which is called as
$(_prompt ...) at lines 58-60. Invisible prompt, and the prompt text gets prepended to the
captured secret. #97 is already in test/azure-stack, so this will conflict — make sure the
merged _prompt keeps prompt text on stderr. Verify by running it over a real pty, not by
reading the diff.

Test:

1. The migration, against the live #115 deployment. That state has the seven secrets in it.
   Plan must be 0 to add, 0 to change, 0 to destroy. Apply, then confirm the vault still
   holds all seven secrets and that their version IDs are byte-identical before and after —
   dropped from state, not deleted and recreated. Then re-plan and confirm No changes.
2. The PR's own declared gap: it tested removed blocks declared at ROOT, but ships them in
   a child module (modules/keyvault/removed.tf) with module-local addresses. That is the
   untested case and it is the one that ships. Test it explicitly.
3. Second declared gap: the scratch vault used access-policy auth, so
   time_sleep.wait_for_rbac was never exercised. The #115 vault is RBAC. Confirm the
   propagation path works.
4. Third gap: only three of the seven addresses were exercised. Confirm all seven.
5. make seed-secrets against the real vault. Confirm it writes only missing secrets, that
   each Fernet key is 44 chars of url-safe base64 decoding to exactly 32 bytes with no
   trailing whitespace, and that re-running with LANGSMITH_ADMIN_PASSWORD set to a
   different value leaves every version ID unchanged. Write-once has to hold.
6. Confirm the plaintext never reaches the process list — capture argv while az runs.
   Confirm the umask 077 temp files are 0600 and are cleaned up, including on a mid-run
   failure.
7. Admin password rules moved to _common.sh. Confirm make keyvault set and the seed script
   enforce identically, and that a password Azure accepts but the chart's auth-bootstrap
   job rejects now fails at the prompt instead of ten minutes into the release.
8. Full flow on a fresh throwaway deployment: make setup-env -> make apply -> make
   seed-secrets -> make k8s-secrets -> make deploy. LangSmith must come up. Destroy after.
9. Grep the state file for every one of the seven secret values and confirm none appear.
   That is the entire point of the PR and it deserves a direct check.

On success, post a comment on the PR: Terraform version and subscription on one line, then a
numbered list, one line per step, what you ran and what you observed. Step 1's line carries
the version-ID comparison; step 9's carries the grep as a match count. Never paste a secret
value, not even truncated. Nothing else. No summary, no caveats, no notes, no description of
the change. Which approach you took and why goes to me, not the comment. Then stop for my
review before merging.
````

---

## Order and why

| # | PR | Fixture | Conflicts with |
|---|---|---|---|
| 1 | #120 TF 1.11 floor | none, init and validate only | 118 |
| 2 | #97 setup-env prompts | throwaway Postgres server + Key Vault | — |
| 3 | #105 preflight RBAC | real subscription, scratch SP + apply as that SP | — |
| 4 | #115 wizard + BYO networking | **greenfield apply, keep alive** | 105 |
| 5 | #124 clickhouse external | the #115 cluster + external ClickHouse | — |
| 6 | #113 AKS zone postcondition | the #115 cluster | 115 |
| 7 | #109 AMR SKU + HA | the #115 AMR, plus westus2 for B3 | 115, 124 |
| 8 | #106 principal_type | the #115 deployment's existing state + scratch RG/SP | 115, 105 |
| 9 | #95 BYO cluster + KV | own fixture from origin/test/azure-e2e | 115, 106 |
| 10 | #116 secrets out of state | the #115 deployment + a throwaway one | 97, 120 |

#94 was here at slot 2 and merged upstream on 2026-08-11, so it drops out of the sequence. Its
GUID validation now arrives from `origin/main` in both `infra/variables.tf` and
`app/variables.tf`, which is where the later threads pick it up.

#120 leads because it needs nothing to test against. It sat at slot 10 on the strength of its
own step 4, a no-op plan and apply against the #115 deployment — a test that could not fail,
since `required_version` is a CLI gate that appears in no resource schema and so cannot change
a plan. That step is gone and the fixture dependency with it. Steps 1 through 3 are the real
tests: a consistent floor across modules, init and validate on 1.11.0 and 1.14.6, and a clean
refusal on 1.10.5. It merges clean into the rebuilt stack, verified with `git merge-tree`.

Every thread runs Terraform 1.11.0 via `mise use terraform@1.11.0`, except #120, which tests
1.11.0, 1.14.6, and 1.10.5 as a matrix because the version is the subject there. With #120
first, the floor each thread pins is the floor the tree declares. It is not a state
compatibility constraint, since a 1.11.0 CLI reads state written by 1.14.6 without error.

**Stacking.** None of these PRs are merged, and merging is blocked on review, so the sequence
runs against a local integration branch instead: `test/azure-stack`, built off `origin/main`
with each passing PR merged in. It was rebuilt on 2026-08-11 onto `origin/main` at `74b856b`,
which by then carried the chart 0.16 cutover and #94, and it now holds two merges, #97 and
#105, both clean with no hand resolution. #120 merges in on top of them. The pre-rebuild branch
is parked at `test/azure-stack-pre-0.16` if anything needs comparing. Each thread does
`git worktree add .claude/worktrees/prNNN-stack -b test/prNNN-on-stack test/azure-stack`,
merges `origin/<pr-branch>` into it, and tests that. On a pass I move `test/azure-stack`
forward so the next thread inherits the resolution rather than redoing it. Threads never move
that branch themselves and never push. Every prompt verifies the base with
`git log --oneline --merges origin/main..test/azure-stack`, which lists the stack's own merges
and no upstream ones, so it stays correct as `origin/main` moves.

From #115 onward the stacking is a correctness requirement, not a convenience. The five
threads after it share one Terraform state, and #115 renames every resource. A tree without
#115 planning against that state would propose destroying and recreating the whole
deployment.

**Shared state.** #115 builds the deployment that #124, #113, #109, #106, and #116 all
attach to, so those five threads point at one remote key:
`terraform/state/langsmith-devfreddy` in `langchainterraformstate`/`tfstate`, resource group
`terraform-state-rg`. Each writes `modules/azure/infra/backend_override.tf` before its first
`init`, because that file is gitignored and a fresh worktree silently falls back to empty
local state. Threads 1, 2, 3, and 9 use local state and must not create that file. The
same container holds `terraform/state/langsmith-dev` and `terraform/state/azure-org`, both live
and shared, so no thread invents its own key.

**#81** (Azure private landing zone, external fork, new `modules/azure-private/` tree) ships
its own hub-spoke fixture and shares none with the above, so sequence it anywhere. Its review
has to require `>= 1.11.0` on the five new `versions.tf` files it adds under
`modules/azure-private/`. They land at `>= 1.5`, which puts sub-floor modules back in the tree
after #120, and #120 cannot catch them because it only edits files that already exist.

**Cross-cloud tail**: #118 deletes `modules/azure/app/`, which #117 edits, and moots #117. It
also deletes all three `app/versions.tf` files, three of #120's four module bumps; floor-first
makes that trivial, since #118's deletion wins on rebase. Settle 118-vs-117 as one decision
after this line is clear. #104 and #121 are docs and tooling, one trivial resolution each.
#119 merged as the 0.16 release.
