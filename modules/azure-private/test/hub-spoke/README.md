# Test scaffold — hub-and-spoke + Azure Firewall for `azure-private`

> **This is Path A, step 1.** This scaffold builds the *prerequisite* network so you can
> test-drive the module without an enterprise VNet. Apply it, grab its output, then continue with
> the deploy runbook — [`../../DEPLOYMENT.md`](../../DEPLOYMENT.md) from **Phase 1** onward — for
> the `infra/` apply, the jumpbox bootstrap, and the Helm install.

> **Test-only.** This stands up the *prerequisite* network that `modules/azure-private`
> consumes (it's a BYO-VNet module). It is **not** part of a production deployment. It deploys
> into an **existing resource group** (`var.resource_group_name`, default `rg-langsmith-test`) and
> never creates or deletes that RG — `terraform destroy` removes only the scaffold's resources.
> **It runs an Azure Firewall and a VM — it costs money while up.** Tear it down when done.

## What it creates

```
Hub VNet 10.0.0.0/16
  ├─ AzureFirewallSubnet            (10.0.0.0/26)
  ├─ AzureFirewallManagementSubnet  (10.0.0.64/26)   ← required by Firewall Basic
  └─ Azure Firewall (Basic) + policy: allow AKS egress
        • app rule:  AzureKubernetesService FQDN tag (80/443)
        • net rules: UDP 1194 + TCP 9000 → AzureCloud, UDP 123 (NTP)
Spoke VNet 10.1.0.0/16
  ├─ aks         (10.1.0.0/22)  route table 0.0.0.0/0 → firewall; SE: Storage + KeyVault
  ├─ postgres-pe (10.1.4.0/24)  private-endpoint subnet (NOT delegated)
  ├─ redis-pe    (10.1.5.0/24)  private-endpoint subnet
  └─ jumpbox     (10.1.6.0/24)  apply-host VM (public IP, SSH from your CIDR only)
Peering hub <-> spoke (forwarded traffic allowed)
```

## Apply the scaffold (from anywhere)

```bash
cd modules/azure-private/test/hub-spoke
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, allowed_ssh_cidr (your IP/32), jumpbox_ssh_public_key
terraform init
terraform apply

# Grab the two values the deploy runbook needs:
terraform output azure_private_tfvars     # paste into ../../infra/terraform.tfvars
terraform output -raw jumpbox_ssh         # SSH command for the apply host (used at Phase 3)
```

**Next → [`../../DEPLOYMENT.md`](../../DEPLOYMENT.md) from Phase 1.** Paste `azure_private_tfvars`
into `infra/terraform.tfvars`, then follow the phases (infra apply → jumpbox bootstrap → secrets →
Helm). The `jumpbox_ssh` output is your in-VNet apply host for the `bootstrap/` phases.

## Notes

- **CIDR overlap:** `azure-private`'s default `aks_service_cidr` (`10.0.64.0/20`) overlaps the
  hub `10.0.0.0/16`. The `azure_private_tfvars` output already overrides it to `10.2.0.0/20`
  (with `aks_pod_cidr = 10.244.0.0/16`) — keep those non-overlapping values.
- **Two VMs in the jumpbox subnet:** `azure-private` also provisions its own bastion VM (always
  on) in `bastion_subnet_id`. That's fine — this scaffold's jumpbox is your *apply host*; the
  module's bastion is for day-2 access.
- **System private DNS:** with `aks_private_dns_zone_id = ""`, AKS auto-links its API-server
  zone to the spoke VNet, so the jumpbox resolves the private API. No custom DNS forwarder is
  needed in this basic setup.
- **`infra/` is not blocked by the private API.** Apply it from anywhere. Only `bootstrap/`
  needs VNet connectivity (it uses the Kubernetes and Helm providers).

## Teardown

Tear down the module first (see [`../../DEPLOYMENT.md` § Teardown](../../DEPLOYMENT.md#teardown) —
`bootstrap/` from the jumpbox, then `infra/`), **then** destroy this scaffold:

```bash
cd modules/azure-private/test/hub-spoke && terraform destroy
```
