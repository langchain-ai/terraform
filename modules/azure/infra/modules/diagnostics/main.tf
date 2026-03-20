# ══════════════════════════════════════════════════════════════════════════════
# Module: diagnostics
# Purpose: Azure Monitor Log Analytics workspace + diagnostic settings.
#
# Captures control-plane audit logs from:
#   • AKS  — kube-audit, kube-apiserver, kube-scheduler, cluster-autoscaler
#   • Key Vault — AuditEvent (who read/wrote secrets, and when)
#   • PostgreSQL — PostgreSQLLogs (slow queries, failed auth)
#
# Equivalent to AWS CloudTrail for Azure. Required for SOC2 / enterprise
# customers who need an immutable audit trail of infrastructure operations.
# ══════════════════════════════════════════════════════════════════════════════

# Log Analytics Workspace — the central sink for all diagnostic data.
resource "azurerm_log_analytics_workspace" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_days
  tags                = merge(var.tags, { module = "diagnostics" })
}

# AKS diagnostic settings — captures control-plane logs.
# kube-audit: every API server request (create, delete, exec, etc.)
# kube-audit-admin: admin-level operations only (lower volume)
# cluster-autoscaler: scale-up/scale-down decisions
resource "azurerm_monitor_diagnostic_setting" "aks" {
  count                      = var.aks_id != "" ? 1 : 0
  name                       = "${var.name}-aks-diag"
  target_resource_id         = var.aks_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "kube-audit" }
  enabled_log { category = "kube-audit-admin" }
  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "cluster-autoscaler" }
  enabled_log { category = "guard" }

  enabled_metric {
    category = "AllMetrics"
    enabled  = false
  }
}

# Key Vault diagnostic settings — captures every secret read/write.
# AuditEvent: who accessed which secret, from which IP, and the result.
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  count                      = var.keyvault_id != "" ? 1 : 0
  name                       = "${var.name}-kv-diag"
  target_resource_id         = var.keyvault_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  enabled_metric {
    category = "AllMetrics"
    enabled  = false
  }
}

# PostgreSQL diagnostic settings — captures slow queries and auth failures.
resource "azurerm_monitor_diagnostic_setting" "postgres" {
  count                      = var.postgres_id != "" ? 1 : 0
  name                       = "${var.name}-postgres-diag"
  target_resource_id         = var.postgres_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "PostgreSQLLogs" }

  enabled_metric {
    category = "AllMetrics"
    enabled  = false
  }
}
