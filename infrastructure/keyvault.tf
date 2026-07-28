resource "azurerm_key_vault" "this" {
  name                = "${local.compact_name}kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC rather than legacy access policies: role assignments are auditable and
  # manageable with the same tooling as the rest of the estate.
  enable_rbac_authorization = true

  # A vault holding production credentials must not be recoverable by accident
  # nor quickly destroyable.
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  tags = local.common_tags
}

# The pipeline identity needs to write the generated secrets during apply.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The application identity only ever needs to read them.
resource "azurerm_role_assignment" "app_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "database-password"
  value        = random_password.db_admin.result
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"
  tags         = local.common_tags

  # RBAC propagation must complete before the first write.
  depends_on = [azurerm_role_assignment.deployer_secrets_officer]

  lifecycle {
    # Rotated out of band; Terraform should not revert a rotated password.
    ignore_changes = [value]
  }
}

# Non-secret connection details are stored alongside the password so that the
# vault is the single source of truth for anything wiring up to this database.
resource "azurerm_key_vault_secret" "db_username" {
  name         = "database-username"
  value        = azurerm_postgresql_flexible_server.this.administrator_login
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"
  tags         = local.common_tags

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "db_host" {
  name         = "database-host"
  value        = azurerm_postgresql_flexible_server.this.fqdn
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"
  tags         = local.common_tags

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "db_name" {
  name         = "database-name"
  value        = azurerm_postgresql_flexible_server_database.this.name
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"
  tags         = local.common_tags

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

# Diagnostic logging for the vault - read which secret, and when.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "${local.name_prefix}-kv-diag"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
