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
  - HCL edit → `bash agents/check.sh <terraform-root-dir>`: `terraform validate`
    plus `tflint` with the provider's pinned ruleset from
    `modules/<provider>/.tflint.hcl`.
  - Shell edit → `bash agents/check.sh --scripts`: `shellcheck` over every
    tracked `*.sh`. No terraform, so it returns in about a second.
  - No argument → both, across every root.

  **shellcheck fails on warnings** (the repo is clean at that bar — keep it
  there); tflint fails only on errors, because the HCL still carries
  pre-existing warnings. Override for a one-off run with
  `SHELLCHECK_SEVERITY=info` or `TFLINT_SEVERITY=warning`. `terraform plan`
  needs cloud creds and state — never run it without explicit user approval.
- **CI runs the same script**, one job per provider plus one for the scripts, so
  a green local run is a green PR. If you change what the gate covers, change
  `agents/check.sh` rather than the workflow. A new root under an existing
  `modules/<provider>/` needs no workflow edit; a brand-new provider directory
  needs a `matrix.provider` entry in `.github/workflows/checks.yaml`.
- Read-only cloud commands (`get`/`describe`/`list`) are fine unprompted.
  Anything mutating — `apply`, `plan` against real state, cloud-CLI writes —
  needs explicit approval first.
