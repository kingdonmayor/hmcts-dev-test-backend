# A user-assigned identity is used rather than a system-assigned one so that the
# Key Vault role assignment can be created before the app that consumes it
resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name_prefix}-id"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.common_tags
}

# Pull rights on the registry holding the application image.
resource "azurerm_role_assignment" "app_acr_pull" {
  count = var.container_registry_id == null ? 0 : 1

  scope                = var.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app_environment" "this" {
  name                       = "${local.name_prefix}-cae"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.common_tags
}

resource "azurerm_container_app" "this" {
  name                         = "${local.name_prefix}-ca"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # The password is pulled from Key Vault at revision start using the managed
  # identity. Terraform never writes the value into the Container App resource,
  # it does not appear in the app definition
  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.db_password.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  registry {
    server   = var.container_registry_login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = var.ingress_external_enabled
    target_port      = var.container_port
    transport        = "auto"
    # Reject plaintext at the edge.
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = tostring(var.http_concurrent_requests_per_replica)
    }

    container {
      name   = var.component
      image  = "${var.container_registry_login_server}/${var.container_image_name}:${var.container_image_tag}"
      cpu    = var.container_cpu
      memory = var.container_memory

      # Application configuration as environment variables  
      env {
        name  = "SERVER_PORT"
        value = tostring(var.container_port)
      }

      env {
        name  = "DB_HOST"
        value = azurerm_postgresql_flexible_server.this.fqdn
      }

      env {
        name  = "DB_PORT"
        value = "5432"
      }

      env {
        name  = "DB_NAME"
        value = azurerm_postgresql_flexible_server_database.this.name
      }

      env {
        name  = "DB_USER_NAME"
        value = azurerm_postgresql_flexible_server.this.administrator_login
      }

      # Azure PostgreSQL rejects non-TLS connections.
      env {
        name  = "DB_OPTIONS"
        value = "?sslmode=require"
      }

      # Injected from the Key Vault-backed secret above, never as a literal.
      env {
        name        = "DB_PASSWORD"
        secret_name = "db-password"
      }

      # Liveness uses the plain health endpoint; readiness uses the `db` group,
      # so a replica only receives traffic once its datasource is reachable.
      liveness_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health"
        initial_delay           = 30
        interval_seconds        = 15
        timeout                 = 5
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health/readiness"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
        success_count_threshold = 1
      }

      startup_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 30
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.app_secrets_user,
    azurerm_postgresql_flexible_server_database.this,
  ]
}

resource "azurerm_monitor_diagnostic_setting" "container_app" {
  name                       = "${local.name_prefix}-ca-diag"
  target_resource_id         = azurerm_container_app.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }
}
