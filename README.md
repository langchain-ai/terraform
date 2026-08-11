# langchain-ai/terraform

Terraform modules for deploying **LangSmith Self-Hosted** on AWS, Azure, GCP, and OpenShift.

LangSmith is LangChain's observability, evaluation, and prompt-engineering platform. This repository packages the cloud foundation (network / cluster / database / cache / object storage / secrets / DNS) and the Helm deployment of the LangSmith application as reusable, production-ready Terraform.

## Who this is for

Enterprise customers running LangSmith in their own cloud account or OpenShift cluster. If you are evaluating Self-Hosted or standing up a production deployment, start here.

For LangSmith fundamentals and architecture, see the [Self-Hosted documentation](https://docs.langchain.com/langsmith/deploy-self-hosted-full-platform).

## Pick your cloud

| Provider | Guide | Cluster | Status |
|---|---|---|---|
| AWS | [`modules/aws/`](modules/aws/README.md) | EKS | GA |
| Azure | [`modules/azure/`](modules/azure/README.md) | AKS | GA |
| GCP | [`modules/gcp/`](modules/gcp/README.md) | GKE | GA |
| OpenShift | [`modules/ocp/`](modules/ocp/README.md) | OCP / ROSA | Preview |

Each provider directory is a self-contained deployment with a `Makefile`, an `infra/` Terraform layout, Helm values, and operator scripts. The shared module structure is described in [`modules/README.md`](modules/README.md).

## What you get

- **Two-pass deploy.** `infra/` provisions the cloud foundation; the Helm scripts install the LangSmith chart.
- **Secrets via your cloud's native store** (AWS SSM, Azure Key Vault, GCP Secret Manager), synced into Kubernetes by [External Secrets Operator](https://external-secrets.io/) — no secrets in git, no secrets in `tfvars`.
- **Sizing profiles:** `dev`, `production`, `production-large` — selected with a single variable.
- **Enterprise feature toggles:**
  - LangGraph Platform / Deployments
  - Agent Builder
  - Insights (ClickHouse-backed analytics)
  - Polly (AI evaluation & monitoring)
- **Optional hardening (AWS today):** AWS Network Firewall (FQDN egress), WAFv2, CloudTrail, private EKS API endpoint with SSM bastion.
- **Ingress flexibility:** cloud-native load balancers by default, or Envoy Gateway (Gateway API) for multi-namespace dataplane deployments.

## Deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|---|---|---|---|---|
| **Dev / POC** | In-cluster | In-cluster | In-cluster | Demos, evaluations |
| **Production** | Cloud-managed (RDS / Cloud SQL / Azure DB) | Cloud-managed | [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) | Scalable, persistent |

> Blob storage (S3 / GCS / Azure Blob) is always required — trace payloads must not live in ClickHouse. See [self-host blob storage](https://docs.langchain.com/langsmith/self-host-blob-storage).
>
> In-cluster ClickHouse is for dev / POC only. Production deployments should use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

## Getting started

1. **Check out the latest release tag, not `main`** — see [Versioning and releases](#versioning-and-releases) for the one-line command. `main` is the development branch and may move under you.
2. Pick the provider folder above and read its `README.md`.
3. Install the prerequisites it lists (Terraform ≥ 1.5, `kubectl`, `helm`, and your cloud CLI).
4. Run the interactive wizard (`make quickstart` on AWS; equivalent setup on Azure / GCP).
5. `make apply` → `make deploy`.

A typical first deployment takes 20–30 minutes end-to-end.

## Versioning and releases

This repository is released as **global tags** `vMAJOR.MINOR.PATCH`. Always deploy from a tag — never from a branch.

- **`MAJOR.MINOR` is the supported LangSmith Helm chart line.** The deploy scripts pin the chart to that line (for example `~0.16.0`, meaning the latest `0.16.x`), so a deployment never silently jumps across a breaking minor (e.g. to `0.17`). You always get the newest patch within the line.
- **`PATCH` is the module revision.** It increments on any change to this repository, regardless of provider, and is **not** the chart version — `v0.16.4` does not mean chart `0.16.4`.

Check out the latest tag on the line (don't hardcode a patch — `git checkout` needs a real tag, and ranges like `v0.16.x` are not valid):

```bash
git fetch --tags
git checkout "$(git tag -l 'v0.16.*' --sort=-v:refname | head -1)"
```

If you would rather download than clone, every release has a source archive — one URL per release, covering all providers:

```bash
TAG=v0.16.0     # latest v0.16.* — see GitHub Releases below
curl -sL "https://github.com/langchain-ai/terraform/archive/refs/tags/${TAG}.zip" -o "${TAG}.zip"
unzip "${TAG}.zip"     # extracts terraform-0.16.0/
```

GitHub generates these archives on request, so don't pin a checksum of one; clone and check out the tag if you need bit-for-bit reproducibility.

What this means for you:

- Pin to a tag for reproducible infrastructure; re-run the command above to move to a newer patch within the line as fixes land.
- Moving to a new chart line is an explicit switch to the matching tag series (`git tag -l 'v0.17.*'`).
- **Staying on the previous line is supported.** `0.15` is maintained on the `release/0.15` branch and still receives `v0.15.*` tags, so you can take fixes without moving to `0.16`. See [Maintenance branches](#maintenance-branches).
- Browse all releases in [GitHub Releases](https://github.com/langchain-ai/terraform/releases).
- Advanced override: set the `CHART_VERSION` environment variable to pin an exact chart patch.

### The 0.16 chart line

These modules carry the chart 0.16 values schema: `engineInsightsAgent`, the top-level
`insights` / `polly` blocks, and no `backend.agentBootstrap`. Chart 0.15 ignores those
keys instead of rejecting them, so it would render cleanly while quietly dropping the
external Insights database wiring, and chart 0.17 has not been validated against them.
Each `deploy.sh` therefore refuses anything outside the 0.16 line rather than deploying
a half-configured release, and `CHART_VERSION` can only narrow the pin to a 0.16 patch:

```bash
cd modules/aws && make apply && make init-values && CHART_VERSION="0.16.0" make deploy
```

Read [MIGRATION-0.15-to-0.16.md](MIGRATION-0.15-to-0.16.md) before upgrading an existing
install — the values schema changed in ways the chart rejects outright.

### Maintenance branches

The current chart line is developed on `main`. When the pinned line moves, the outgoing
line moves to a `release/<line>` branch and keeps releasing from there — the release
workflow scopes its patch lookup to the line it finds pinned, so both branches cut tags on
their own series without colliding.

| Chart line | Releases from | Tag series | Status |
| --- | --- | --- | --- |
| 0.16 | `main` | `v0.16.*` | current |
| 0.15 | `release/0.15` | `v0.15.*` | maintenance |

Deploying or upgrading within the 0.15 line works exactly as before — check out its latest
tag, not the branch:

```bash
git fetch --tags
git checkout "$(git tag -l 'v0.15.*' --sort=-v:refname | head -1)"
```

Report an issue against the line you are running. Fixes land on `main` first and are
backported to a maintenance branch where they apply cleanly; values-schema changes tied to
the newer chart are not backported, because the older chart ignores the affected keys rather
than rejecting them and would deploy a half-configured release.

Only `release/<line>` releases. The next line is staged on a `cutover/<line>` branch, which
releases nothing until it merges to `main` — keeping the two prefixes distinct is what stops
a line still under test from cutting tags.

The per-release history is published in [GitHub Releases](https://github.com/langchain-ai/terraform/releases).

> Tags are immutable. Use `pre-terraform-migration` only for the legacy pre-`0.15` state (see [History](#history)).

## Documentation

- [LangSmith Self-Hosted overview](https://docs.langchain.com/langsmith/deploy-self-hosted-full-platform)
- [Kubernetes deployment reference](https://docs.langchain.com/langsmith/kubernetes)
- [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse)
- [Self-host blob storage](https://docs.langchain.com/langsmith/self-host-blob-storage)
- [Scaling guidance](https://docs.langchain.com/langsmith/self-host-scale)
- [Self-Hosted changelog](https://docs.langchain.com/langsmith/self-hosted-changelog)
- Per-provider architecture and troubleshooting: `modules/<provider>/ARCHITECTURE.md` and `TROUBLESHOOTING.md`

## Support

- **Enterprise customers:** start at [enterprise-hub.langchain.com](https://enterprise-hub.langchain.com/) — the front door for onboarding, education, professional services, and support.
- **Customers with a LangChain support agreement:** open a ticket through your usual support channel.
- **General questions:** contact your LangChain account team.
- **Bugs and feature requests for these modules:** open an issue on this repository.

## History

This repository was reseeded from the LangChain Professional Services internal repo. The pre-migration state (the parallel module set previously under `modules/`) is preserved at:

- Tag: `pre-terraform-migration`
- Branch: `archive/pre-terraform-migration`

## License

Apache 2.0 — see [LICENSE](./LICENSE).
