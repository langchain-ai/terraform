# ══════════════════════════════════════════════════════════════════════════════
# State moves: un-counted → counted
#
# Adding `count` to a resource changes its state address from
# azurerm_key_vault.langsmith to azurerm_key_vault.langsmith[0]. Without these
# blocks, the first plan after upgrading reads that as "destroy the old address,
# create the new one" and proposes deleting a live Key Vault. Purge protection
# would then block the delete and the recreate would collide with the name still
# held by soft delete, so the upgrade would strand the deployment rather than
# fail cleanly.
#
# A moved block whose source is absent from state is a no-op, so these are inert
# for fresh deployments on either path. They can be dropped once every
# deployment has applied once on this version or later.
# ══════════════════════════════════════════════════════════════════════════════

moved {
  from = azurerm_key_vault.langsmith
  to   = azurerm_key_vault.langsmith[0]
}

moved {
  from = azurerm_role_assignment.terraform_kv_admin
  to   = azurerm_role_assignment.terraform_kv_admin[0]
}

moved {
  from = azurerm_role_assignment.managed_identity_kv_reader
  to   = azurerm_role_assignment.managed_identity_kv_reader[0]
}

moved {
  from = time_sleep.wait_for_rbac
  to   = time_sleep.wait_for_rbac[0]
}
