# AGENTS.md — repo conventions for agent work

Conventions for AI agents editing this repo. Facts about provider arguments
live in `agents/schema/*.json` (generated ground truth, gitignored) — this file
is conventions only.

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
  `init-values.sh`, secrets managers). Linted as part of the provider, not the
  root, since they drive the `app` root.
- `modules/<provider>/infra/modules/<name>/` — internal child modules
  (networking, k8s-cluster, postgres, redis, storage, dns, secrets, iam…).
  Local `source = "./modules/..."` only; no registry module publishing here.
  Validated transitively via `--call-module-type=all`, not as their own roots —
  even the two that carry a `versions.tf` (azure `keyvault`, azure `redis`), so
  the gate identifies a child module by its path, not by depth.
- Not gated: `modules/ocp` — the OpenShift port is still stubs with no
  `versions.tf` anywhere, so there is nothing to init against. Edit with extra
  care; `terraform fmt -check` is the only automated cover it has.
- `.terraform.lock.hcl`, `*.tfvars`, `*.tfstate*` are gitignored per provider
  dir. Lock files on disk are the pinned provider versions — read them, don't
  guess versions.

## Workflow contract

- **Before writing HCL**, check `versions.tf` (constraints) and
  `.terraform.lock.hcl` (resolved pins) in the root you're editing. Write
  against the pinned version, not training-data defaults.
- **Work in small units**: one resource or module, run the checks below, then
  continue. Don't write 300 lines and hand back a correction cycle.
- **Machine-graded before handing back**: after every HCL or shell edit run
  `bash agents/check.sh <terraform-root-dir>` (no argument checks every root)
  and fix what it reports. Per root it runs `terraform validate`, `tflint` with
  the provider's pinned ruleset from `modules/<provider>/.tflint.hcl`, and
  `shellcheck` over the provider's `*.sh`. **shellcheck fails on warnings** (the
  repo is clean at that bar — keep it there); tflint fails only on errors,
  because the HCL still carries pre-existing warnings. Override for a one-off
  run with `SHELLCHECK_SEVERITY=` or `TFLINT_SEVERITY=`. `terraform plan` needs
  cloud creds and state — never run it without explicit user approval.
- **CI runs the same script**, one job per provider, so a green local run is a
  green PR. If you change what the gate covers, change `agents/check.sh` rather
  than the workflow, and the workflow picks it up.
- **Schema ground truth**: `agents/schema/<provider>-<root>.schema.json` is
  `terraform providers schema -json` for the pinned versions. Grep it for
  exact attribute names/types instead of relying on memory. Regenerate with
  `bash agents/dump-schemas.sh` after any provider upgrade (or just delete
  the file — check.sh regenerates on demand).
- Read-only cloud commands (`get`/`describe`/`list`) are fine unprompted.
  Anything mutating — `apply`, `plan` against real state, cloud-CLI writes —
  needs explicit approval first.
