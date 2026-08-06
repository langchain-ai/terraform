# AGENTS.md — repo conventions for agent work

Local, uncommitted companion for AI agents editing this repo. Facts about
provider arguments live in `agents/schema/*.json` (generated ground truth) —
this file is conventions only.

## Layout

- `modules/<provider>/{infra,app}` — each is its own Terraform root: own
  `versions.tf`, `backend.tf`, state. Providers: `aws`, `azure`, `gcp`, `ocp`.
  `infra/` provisions the cloud foundation; `app/` Helm-deploys LangSmith.
- `modules/<provider>/infra/modules/<name>/` — internal child modules
  (networking, k8s-cluster, postgres, redis, storage, dns, secrets, iam…).
  Local `source = "./modules/..."` only; no registry module publishing here.
- `ocp/infra` is mostly stubs.
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
  `bash agents/check.sh <terraform-root-dir>` and fix what it reports. It runs
  `terraform validate`, `tflint` (provider plugin, errors fail), and
  `shellcheck -S error` over the provider's `*.sh` scripts. `terraform plan`
  needs cloud creds and state — never run it without explicit user approval.
- **Schema ground truth**: `agents/schema/<provider>-<root>.schema.json` is
  `terraform providers schema -json` for the pinned versions. Grep it for
  exact attribute names/types instead of relying on memory. Regenerate with
  `bash agents/dump-schemas.sh` after any provider upgrade (or just delete
  the file — check.sh regenerates on demand).
- Read-only cloud commands (`get`/`describe`/`list`) are fine unprompted.
  Anything mutating — `apply`, `plan` against real state, cloud-CLI writes —
  needs explicit approval first.
