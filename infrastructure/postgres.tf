# The administrator password is generated here and written straight to Key Vault.
# It is never entered , never passed as a tfvar, and never appears in
# the repository. It does land in Terraform state, which is why the state backend
# must be encrypted and RBAC-restricted see versions.tf.
resource "random_password" "db_admin" {
  length  = 32
  special = true
  # Excludes characters that Azure rejects or that break connection strings.
  override_special = "!#%*()-_=+[]{}:?"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${local.name_prefix}-psql"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  version             = var.postgres_version

  administrator_login    = var.db_admin_username
  administrator_password = random_password.db_admin.result

  sku_name   = var.postgres_sku_name
  storage_mb = var.postgres_storage_mb
  zone       = "1"

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

  # See README trade-offs: production would place this on a delegated subnet with
  # a private DNS zone instead of using the service firewall.
  public_network_access_enabled = true

  dynamic "high_availability" {
    for_each = var.postgres_high_availability_enabled ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      # Rotation is handled out of band (see README), not by re-running apply.
      administrator_password,
      # Azure may move the server between zones during maintenance.
      zone,
    ]
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# Reject any connection that is not TLS-encrypted.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

# Log every failed connection attempt, for audit.
resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

# 0.0.0.0-0.0.0.0 is the Azure convention for "allow Azure-internal services",
# which is how the Container App reaches the server without a public IP allowlist.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Optional, explicit operator access ranges. Empty by default.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allowed_ranges" {
  for_each = var.db_allowed_ip_ranges

  name             = each.key
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = each.value.start_ip_address
  end_ip_address   = each.value.end_ip_address
}
