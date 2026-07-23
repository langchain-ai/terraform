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

Each provider directory is a self-contained deployment with a `Makefile`, a two-pass Terraform layout (`infra/` + `app/`), Helm values, and operator scripts. The shared module structure is described in [`modules/README.md`](modules/README.md).

## What you get

- **Two-pass deploy.** `infra/` provisions the cloud foundation; `app/` (or the Helm scripts) installs the LangSmith chart.
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

This repository is released as **global tags** `vMAJOR.MINOR.PATCH`. Always deploy from a tag — never from `main`.

- **`MAJOR.MINOR` is the supported LangSmith Helm chart line.** The deploy scripts pin the chart to that line (for example `~0.15.1`, meaning the latest `0.15.x`), so a deployment never silently jumps across a breaking minor. Features with a higher minimum chart line fail fast unless you explicitly set a compatible chart version.
- **`PATCH` is the module revision.** It increments on any change to this repository, regardless of provider, and is **not** the chart version — `v0.15.4` does not mean chart `0.15.4`.

Check out the latest tag on the line (don't hardcode a patch — `git checkout` needs a real tag, and ranges like `v0.15.x` are not valid):

```bash
git fetch --tags
git checkout "$(git tag -l 'v0.15.*' --sort=-v:refname | head -1)"
```

What this means for you:

- Pin to a tag for reproducible infrastructure; re-run the command above to move to a newer patch within the line as fixes land.
- Moving to a new chart line (e.g. `0.16` / SmithDB) is an explicit switch to a `v0.16.*` tag (`git tag -l 'v0.16.*'`).
- Browse all releases in [GitHub Releases](https://github.com/langchain-ai/terraform/releases).
- Advanced override: set the `CHART_VERSION` environment variable to pin an exact chart patch. Some features may require setting a compatible minimum chart version explicitly.

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
