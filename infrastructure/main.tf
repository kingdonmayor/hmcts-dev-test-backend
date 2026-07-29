data "azurerm_client_config" "current" {}

locals {
  # so resources are self-describing in the portal.
  name_prefix = "${var.product}-${var.component}-${var.environment}"

  # Key Vault and storage-style names allow no hyphens and are length-capped.
  compact_name = substr(replace(local.name_prefix, "/[^a-z0-9]/", ""), 0, 21)

  common_tags = merge(
    {
      product      = var.product
      component    = var.component
      environment  = var.environment
      businessArea = var.business_area
      costCentre   = var.cost_centre
      managedBy    = "terraform"
      repository   = "hmcts/hmcts-dev-test-backend"
    },
    var.common_tags
  )
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name_prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# Log Analytics workspace for console and system logs.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.name_prefix}-law"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.common_tags
}
