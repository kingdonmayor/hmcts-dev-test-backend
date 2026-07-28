terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state. Deliberately commented out so that `terraform init -backend=false`
  # and `terraform validate` run locally and in CI without Azure credentials.
  #
  # In a real deployment this would point at a dedicated, locked-down storage
  # account in its own "management" resource group, with:
  #   - blob versioning + soft delete enabled (state recovery)
  #   - RBAC-only access, no storage account keys, and `use_azuread_auth = true`
  #   - one state file per environment via the `key` below or `-backend-config`
  #   - state locking handled natively by the azurerm backend's blob lease
  #
  # backend "azurerm" {
  #   resource_group_name  = "hmcts-tfstate-rg"
  #   storage_account_name = "hmctstfstateprod"
  #   container_name       = "tfstate"
  #   key                  = "devtest-backend/prod.terraform.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  # Sourced from ARM_SUBSCRIPTION_ID in CI when the variable is left null.
  subscription_id = var.subscription_id

  features {
    key_vault {
      # Never hard-purge a vault holding production credentials.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "random" {}
