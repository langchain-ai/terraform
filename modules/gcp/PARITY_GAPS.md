# GCP vs AWS Parity Matrix

This file tracks parity against the AWS provider baseline for this repository.

## Current Status

| Area | AWS baseline | GCP status | Classification |
|---|---|---|---|
| Provider task runner | `terraform/aws/Makefile` | `terraform/gcp/Makefile` added | implemented |
| Infra preflight | `aws/infra/scripts/preflight.sh` | `gcp/infra/scripts/preflight.sh` added | implemented |
| Helm preflight + deploy guardrails | `aws/helm/scripts/deploy.sh` | `gcp/helm/scripts/deploy.sh` upgraded to run preflight, refresh kubeconfig, validate inputs | implemented |
| Kubeconfig helper | `aws/infra/scripts/set-kubeconfig.sh` | `gcp/helm/scripts/get-kubeconfig.sh` now supports output/tfvars defaults | implemented |
| IAM / workload identity wiring | EKS IRSA module wiring | `gcp/infra/main.tf` now wires `modules/iam` and annotates KSA | implemented |
| Cloud secrets store wiring | AWS ESO + SSM wiring | `gcp/infra/main.tf` now wires `modules/secrets` behind flag | implemented (optional) |
| DNS / managed cert wiring | AWS `modules/dns` in root | `gcp/infra/main.tf` now wires `modules/dns` behind flag | implemented (optional) |
| Top-level bootstrap tooling | includes `aws` / `az` CLIs | root `Makefile` now installs `gcloud` | implemented |
| WAF integration | `aws/modules/waf` | no GCP equivalent in this provider tree | absent (cloud-specific) |
| Cloud audit trail module | `aws/modules/cloudtrail` | no dedicated GCP audit-log module in this provider tree | absent (cloud-specific) |
| Bastion module | `aws/modules/bastion` | no GCP bastion module | absent (cloud-specific) |
| ALB module | `aws/modules/alb` | GCP uses `modules/ingress` (Gateway API/Envoy model) | intentionally different |

## Flags Added For Safe Adoption

These flags allow parity modules to be enabled progressively in existing environments:

- `enable_gcp_iam_module` (default `true`)
- `enable_secret_manager_module` (default `false`)
- `enable_dns_module` (default `false`)
- `dns_create_zone` (default `true`)
- `dns_existing_zone_name` (default `""`)
- `dns_create_certificate` (default `true`)

## Prioritized Backlog

### P0 (production parity / reliability)

- Add CI check to run `terraform -chdir=terraform/gcp/infra init -backend=false` and `terraform validate`.
- Add a GCP-specific infra status helper (`infra/scripts/status.sh`) with cluster/API/terraform state checks.
- Add a deterministic secrets strategy decision:
  - either keep `enable_secret_manager_module=false` default and document ESO/manual path,
  - or wire full Secret Manager -> K8s sync path in-cluster.

### P1 (high-value operational parity)

- Add optional GCP firewall/WAF guidance path (Cloud Armor) with toggleable module.
- Add GCP module packaging checks in CI aligned with publish workflow expectations.
- Add values layering support in GCP deploy flow if product overlays become common (sizing/features split like AWS).

### P2 (nice-to-have / cloud-specific)

- Add optional GCP bastion/IAP connectivity module pattern.
- Add optional GCP org-level audit logging module equivalent to AWS CloudTrail semantics.
- Add automated post-deploy validation script for GCP (`helm`, `gateway`, `cert-manager`, `keda` health).
