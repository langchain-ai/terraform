Title: fix(azure): remove the namespace ResourceQuota

## Problem

The `langsmith-quota` ResourceQuota in k8s-bootstrap has a fixed base: 40 CPU and 80Gi in requests, 80 CPU and 160Gi in limits, and 200 pods. The production-large profile exceeds it at minimum replica counts, because its core components alone set 122 CPU and 268Gi in limits. The production profile exceeds it at its HPA maximums, at about 57 CPU in requests. Admission rejects every pod past the quota, so those pods never schedule.

The AKS node pool maximum already caps spend, and the AWS module has never set a namespace quota.

## Change

- Delete `kubernetes_resource_quota_v1.langsmith`.
- Keep the `langsmith-defaults` LimitRange with only `default_request` (250m CPU, 256Mi). It gives a container with no requests a figure the scheduler can place. It drops the `default` limits and the `enable_sandboxes` conditional: with no quota, nothing forces a limit onto a pod, and sandbox-host needs none.
- Delete the SmithDB quota headroom: the `resource_quota_extra_*` child inputs, the `smithdb_quota_*` locals, the `smithdb_tiers` table that fed them, and the `smithdb_quota_extra` output.
- Delete `smithdb_migration_parallelism` (variable and output). The quota was its only Terraform use. `deploy.sh` no longer compares it with the migration values file, and `smithdb-migration-job-start.sh` no longer writes it or refuses a parallelism above 30. The warning above 20 stays.
- Drop the quota from the `make apply` stage 2 targets, the docs, and the values example comments.

Applying this deletes `langsmith-quota` from existing namespaces and removes the LimitRange's default limits.

A `terraform.tfvars` that still sets `smithdb_migration_parallelism` gets an undeclared-variable warning. Delete the line.

## Tests

- `sandboxes_absent_when_disabled` and `sandboxes_present_when_enabled` assert that the LimitRange carries the default requests and no default limits, in both directions.
- The quota and parallelism runs in `wiring.tftest.hcl` and `validation.tftest.hcl` are gone with the code they covered.
