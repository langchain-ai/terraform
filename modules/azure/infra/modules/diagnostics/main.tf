# ══════════════════════════════════════════════════════════════════════════════
# Module: diagnostics
# Purpose: Azure Monitor Log Analytics workspace + diagnostic settings.
#
# Captures control-plane audit logs from:
#   • AKS  — kube-audit, kube-apiserver, kube-scheduler, cluster-autoscaler
#   • Key Vault — AuditEvent (who read/wrote secrets, and when)
#   • PostgreSQL — PostgreSQLLogs (slow queries, failed auth)
#   • Application Gateway — access log, and the WAF firewall log when a policy
#     is attached (ingress_controller = "agic")
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
  count                      = var.enable_aks_diag ? 1 : 0
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
  }
}

# Key Vault diagnostic settings — captures every secret read/write.
# AuditEvent: who accessed which secret, from which IP, and the result.
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  count                      = var.enable_keyvault_diag ? 1 : 0
  name                       = "${var.name}-kv-diag"
  target_resource_id         = var.keyvault_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Application Gateway diagnostic settings — the only place the WAF writes what it
# matched. Azure keeps a resource log only for as long as a diagnostic setting
# routes it somewhere, so without this the WAF's Detection mode reports match
# counts through metrics and nothing that identifies the request. Reading the
# firewall log is how you build the exclusion list before switching a policy to
# Prevention, so a WAF without this setting cannot be tuned.
#
# ApplicationGatewayFirewallLog records the matched portion of a request in plain
# text, which is what makes it useful and also means it can hold whatever tripped
# the rule. It stays in this deployment's own Log Analytics workspace under
# retention_days.
resource "azurerm_monitor_diagnostic_setting" "agw" {
  count                      = var.enable_agw_diag ? 1 : 0
  name                       = "${var.name}-agw-diag"
  target_resource_id         = var.agw_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "ApplicationGatewayAccessLog" }
  enabled_log { category = "ApplicationGatewayFirewallLog" }

  # ApplicationGatewayPerformanceLog is deliberately absent: Azure emits it for
  # the v1 SKU only, and this module builds v2. Metrics carry the equivalent.

  enabled_metric {
    category = "AllMetrics"
  }
}

# PostgreSQL diagnostic settings — captures slow queries and auth failures.
resource "azurerm_monitor_diagnostic_setting" "postgres" {
  count                      = var.enable_postgres_diag ? 1 : 0
  name                       = "${var.name}-postgres-diag"
  target_resource_id         = var.postgres_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "PostgreSQLLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}
