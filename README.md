# langchain-ai/terraform

Terraform modules for deploying LangSmith Self-Hosted on AWS, Azure, GCP, and OpenShift.

## Layout

- `modules/aws/` — AWS (EKS) modules and infra root.
- `modules/azure/` — Azure (AKS) modules and infra root.
- `modules/gcp/` — GCP (GKE) modules and infra root.
- `modules/ocp/` — OpenShift / on-prem modules.

Each provider directory contains an `infra/` Terraform root and reusable submodules under `infra/modules/`. See the per-provider `README.md` for usage.

## History

This repository was reseeded from the LangChain Professional Services internal repo. The pre-migration state of this repo (parallel module set previously under `modules/`) is preserved at:

- Tag: `pre-terraform-migration`
- Branch: `archive/pre-terraform-migration`

## License

Apache 2.0 — see [LICENSE](./LICENSE).
