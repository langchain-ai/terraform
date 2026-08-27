# ══════════════════════════════════════════════════════════════════════════════
# State migration: LangSmith app secrets out of Terraform
#
# These seven Key Vault secrets used to be managed by Terraform, which meant
# their plaintext values were persisted in Terraform state. They are now written
# directly to the vault by infra/scripts/seed-keyvault-secrets.sh.
#
# `destroy = false` drops them from state WITHOUT deleting them from Key Vault,
# so existing deployments keep running: the values stay in the vault, the pods
# keep reading them, and only Terraform's ownership goes away.
#
# Deleting these resource blocks without these `removed` blocks would make
# Terraform destroy the vault secrets on the next apply. Soft delete would
# retain them for 90 days, but every pod reading them would break first.
#
# Safe to delete this file once every deployment has applied once on this
# version. Until then, removing it re-introduces the destroy.
# ══════════════════════════════════════════════════════════════════════════════

removed {
  from = azurerm_key_vault_secret.langsmith_admin_password

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault_secret.langsmith_api_key_salt

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault_secret.langsmith_jwt_secret

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault_secret.deployments_encryption_key

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault_secret.agent_builder_encryption_key

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault_secret.insights_encryption_key

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault_secret.polly_encryption_key

  lifecycle {
    destroy = false
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# State migration: postgres_admin_password gained `count`
#
# The secret is now gated by var.manage_secrets, which makes its state address
# indexed. Deployments that applied before this change hold it at the un-indexed
# address, and without this `moved` block Terraform plans a destroy-then-create
# against the vault on the next apply — on the default path, where nothing about
# the deployment has changed at all.
#
# langsmith_license_key needs no equivalent: it carried a `count` already, so it
# has always been stored at [0] and only the count expression changed.
#
# Safe to delete once every deployment has applied once on this version.
# ══════════════════════════════════════════════════════════════════════════════

moved {
  from = azurerm_key_vault_secret.postgres_admin_password
  to   = azurerm_key_vault_secret.postgres_admin_password[0]
}
