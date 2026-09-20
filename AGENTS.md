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
- `modules/<provider>/infra/tests/*.tftest.hcl` — plan tests for that root, run
  by `agents/plan-tests.sh`. Mocked providers, so no credentials and no state.
  Shared provider fixtures live in `tests/mocks/<provider>/*.tfmock.hcl`.
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
  - Conditional wiring, a `validation` block, or a precondition →
    `bash agents/plan-tests.sh modules/<provider>`: `terraform test` plans the
    root against mocked providers, so `length(module.waf) == 0` is assertable
    with no credentials and no state. `validate` resolves no conditionals and
    passes a module gated on a variable nothing sets, which is the gap this
    closes. Suites are `modules/<provider>/infra/tests/*.tftest.hcl`; a new flag
    or gate needs a run there in both directions.

  **shellcheck fails on warnings** (the repo is clean at that bar — keep it
  there); tflint fails only on errors, because the HCL still carries
  pre-existing warnings. Override for a one-off run with
  `SHELLCHECK_SEVERITY=info` or `TFLINT_SEVERITY=warning`. `terraform plan`
  needs cloud creds and state — never run it without explicit user approval.
- **CI runs the same scripts**, a check job and a plan-tests job per provider
  plus one for the scripts, so a green local run is a green PR. If you change
  what the gate covers, change `agents/check.sh` or `agents/plan-tests.sh`
  rather than the workflow. A new root under an existing `modules/<provider>/`
  needs no workflow edit; a brand-new provider directory needs a
  `matrix.provider` entry in both matrices in
  `.github/workflows/checks.yaml`, and a test suite — `plan-tests.sh` exits 2
  on a provider that has neither a suite nor an entry in its `SKIP_PROVIDERS`.
- **US spelling in prose** — comments, docs, and PR bodies: normalize, behavior,
  initialize, not the `-ise`/`-our` forms. No linter covers spelling, so British
  forms slip in from model output unnoticed.
- Read-only cloud commands (`get`/`describe`/`list`) are fine unprompted.
  Anything mutating — `apply`, `plan` against real state, cloud-CLI writes —
  needs explicit approval first.
