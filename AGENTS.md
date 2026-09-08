# AGENTS.md — repo conventions for agent work

Conventions for AI agents editing this repo.

The checks below are the same ones CI runs
(`.github/workflows/checks.yaml`). Running them locally is how you find out
before the PR does, not a separate standard.

## Layout

- `modules/<provider>/{infra,app}` — each is its own Terraform root: own
  `versions.tf`, `backend.tf`, state. `infra/` provisions the cloud foundation;
  `app/` Helm-deploys LangSmith. `aws`, `azure`, and `gcp` have both.
- `modules/byoc/aws/langsmith-byoc-role/` — a seventh root, one level deeper
  than the rest: the customer-side IAM role and break-glass role for BYOC.
  Gated like the others, so run the checks after touching the policies.
- `modules/<provider>/helm/scripts/` — the shell drivers (`deploy.sh`,
  `init-values.sh`, secrets managers). Linted by `check.sh --scripts` along with
  every other tracked script, not per root.
- `modules/<provider>/infra/modules/<name>/` — internal child modules
  (networking, k8s-cluster, postgres, redis, storage, dns, secrets, iam…).
  Local `source = "./modules/..."` only; no registry module publishing here.
  Validated transitively via `--call-module-type=all`, not as their own roots —
  even the two that carry a `versions.tf` (azure `keyvault`, azure `redis`), so
  the gate identifies a child module by its path, not by depth.
- Not gated for terraform: `modules/ocp`. The OpenShift port is still stubs
  with no `versions.tf` anywhere, so there is nothing to init against. Its
  shell scripts are covered (CI lints every tracked `*.sh`); the HCL has only
  `terraform fmt -check`. Edit with extra care.
- `.terraform.lock.hcl`, `*.tfvars`, `*.tfstate*` are gitignored per provider
  dir. Lock files on disk are the pinned provider versions — read them, don't
  guess versions.

## Workflow contract

- **Before writing HCL**, check `versions.tf` (constraints) and
  `.terraform.lock.hcl` (resolved pins) in the root you're editing. Write
  against the pinned version, not training-data defaults. For exact attribute
  names and types, run `terraform providers schema -json` in the root and grep
  it rather than guessing.
- **Work in small units**: one resource or module, run the checks below, then
  continue. Don't write 300 lines and hand back a correction cycle.
- **Machine-graded before handing back**, and fix what it reports:
  - HCL edit → `bash agents/check.sh <dir>`: `terraform validate` plus `tflint`
    with the provider's pinned ruleset from `modules/<provider>/.tflint.hcl`,
    for every root at or beneath the directory you name.
  - Shell edit → `bash agents/check.sh --scripts`: `shellcheck` over every
    tracked `*.sh`. No terraform, so it returns in about a second.
  - No argument → both, across every root.
  - Variable, tfvars, or `TF_VAR_` name change → `bash agents/contracts.sh
    modules/<provider>`: every tfvars key and `TF_VAR_` name the provider's
    shell scripts read, generate, or export has to be a variable that
    `infra/variables.tf` declares. Reads files only, so it needs no terraform
    and returns instantly. One direction: a name in use must be declared, but a
    declared variable that nothing uses is fine — most carry defaults and
    correctly appear in no example. Nothing else catches this. Terraform warns
    and exits 0 on an undeclared tfvars key, ignores an undeclared `TF_VAR_*`
    with no output at all, and an accessor that misses just falls back to its
    default, so a half-finished rename reverts the setting in silence. Your own
    gitignored `infra/terraform.tfvars` is out of scope: CI never sees it, so a
    stray key there stays a terraform warning nothing fails on. Exit 1 is an
    undeclared name; exit 2 means the check could not run (a renamed directory,
    unbalanced braces, a tfvars heredoc whose keys stopped coming out, an
    accessor helper it can neither follow nor name) and needs a fix in
    `contracts.sh` itself, never a workaround in the provider script.

  **shellcheck fails on warnings** (the repo is clean at that bar — keep it
  there); tflint fails only on errors, because the HCL still carries
  pre-existing warnings. Override for a one-off run with
  `SHELLCHECK_SEVERITY=info` or `TFLINT_SEVERITY=warning`. `terraform plan`
  needs cloud creds and state — never run it without explicit user approval.
- **CI runs the same scripts**, one job per provider for each of `check.sh` and
  `contracts.sh`, plus one for the scripts, so a green local run is a green PR.
  If you change what a gate covers, change the script rather than the workflow.
  A new root under an existing `modules/<provider>/` needs no workflow edit; a
  brand-new provider directory needs a `matrix.provider` entry in both matrices
  in `.github/workflows/checks.yaml`.
- **US spelling in prose** — comments, docs, and PR bodies: normalize, behavior,
  initialize, not the `-ise`/`-our` forms. No linter covers spelling, so British
  forms slip in from model output unnoticed.
- Read-only cloud commands (`get`/`describe`/`list`) are fine unprompted.
  Anything mutating — `apply`, `plan` against real state, cloud-CLI writes —
  needs explicit approval first.
