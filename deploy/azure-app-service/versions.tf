terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.42" # 4.42+ for key vault rbac_authorization_enabled
    }
  }
}

# Subscription comes from the environment: export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
provider "azurerm" {
  features {}
}
