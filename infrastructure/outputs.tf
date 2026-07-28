output "resource_group_name" {
  description = "Name of the resource group holding every resource in this configuration."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region the service is deployed to."
  value       = azurerm_resource_group.this.location
}

output "application_url" {
  description = "Public HTTPS URL of the running service."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "health_check_url" {
  description = "Health endpoint, which reports UP only when PostgreSQL is reachable."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}/health"
}

output "container_app_name" {
  description = "Name of the Container App, for pipeline-driven revision updates."
  value       = azurerm_container_app.this.name
}

output "container_app_identity_principal_id" {
  description = "Principal ID of the app's user-assigned identity, for granting further access."
  value       = azurerm_user_assigned_identity.app.principal_id
}

output "postgres_server_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "postgres_database_name" {
  description = "Name of the application database."
  value       = azurerm_postgresql_flexible_server_database.this.name
}

output "postgres_admin_username" {
  description = "Administrator login for the flexible server."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the database credentials."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "URI of the Key Vault, for out-of-band credential retrieval."
  value       = azurerm_key_vault.this.vault_uri
}

output "db_password_secret_id" {
  description = "Versionless Key Vault secret ID for the database password. The value itself is never output."
  value       = azurerm_key_vault_secret.db_password.versionless_id
  sensitive   = true
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace collecting application and platform logs."
  value       = azurerm_log_analytics_workspace.this.id
}
