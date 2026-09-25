data "azurerm_client_config" "current" {}

locals {
  tags = merge(var.tags, { app = "saf3ai-sample-agent" })

  # New registry, or an existing one that already holds the image
  acr_id           = coalesce(one(azurerm_container_registry.acr[*].id), one(data.azurerm_container_registry.existing[*].id))
  acr_login_server = coalesce(one(azurerm_container_registry.acr[*].login_server), one(data.azurerm_container_registry.existing[*].login_server))

  # Env var each provider reads its key from (mock needs none)
  provider_key_env = {
    gemini              = "GEMINI_API_KEY"
    anthropic           = "ANTHROPIC_API_KEY"
    openai              = "OPENAI_API_KEY"
    "azure-openai"      = "AZURE_OPENAI_API_KEY"
    huggingface         = "HF_TOKEN"
    "openai-compatible" = "OPENAI_API_KEY"
  }
  llm_key_env = var.llm_key_env != "" ? var.llm_key_env : lookup(local.provider_key_env, var.llm_provider, "")
  llm_key_set = nonsensitive(var.llm_api_key != "")

  # env var name => Key Vault secret name (names only, no values)
  secrets = {
    for name in compact(["SAF3AI_API_KEY", local.llm_key_set ? local.llm_key_env : ""]) :
    name => name == "SAF3AI_API_KEY" ? "saf3ai-api-key" : "llm-api-key"
  }

  # Plain settings; empty values are dropped so the agent's own defaults apply
  env = {
    for k, v in merge(
      {
        SAF3AI_COLLECTOR_AGENT  = var.saf3ai_collector_agent
        SAF3AI_SCANNER_ENDPOINT = var.saf3ai_scanner_endpoint
        SAF3AI_AGENT_ID         = var.saf3ai_agent_id
        SAF3AI_SERVICE_NAME     = coalesce(var.saf3ai_service_name, var.saf3ai_agent_id)
        SAF3AI_ENVIRONMENT      = var.saf3ai_environment
        SAF3AI_ENFORCEMENT      = var.saf3ai_enforcement
        SAF3AI_FAIL_MODE        = var.saf3ai_fail_mode
        LLM_PROVIDER            = var.llm_provider
        LLM_MODEL               = var.llm_model
      },
      var.extra_env,
    ) : k => v if v != ""
  }

  # Secrets as Key Vault references, resolved by App Service with the app's identity
  key_vault_refs = {
    for name, secret in local.secrets :
    name => "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.agent[name].versionless_id})"
  }
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# ------------------------------------------------------------------ registry
resource "azurerm_container_registry" "acr" {
  count = var.create_acr ? 1 : 0

  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false # pulls use the managed identity
  tags                = local.tags
}

data "azurerm_container_registry" "existing" {
  count = var.create_acr ? 0 : 1

  name                = var.acr_name
  resource_group_name = coalesce(var.acr_resource_group_name, var.resource_group_name)
}

# ------------------------------------------------------------------ Key Vault
resource "azurerm_key_vault" "kv" {
  name                       = var.key_vault_name
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# Lets whoever runs Terraform write the secrets
resource "azurerm_role_assignment" "deployer_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Values come from sensitive variables; they are stored in Terraform state
resource "azurerm_key_vault_secret" "agent" {
  for_each = local.secrets

  name         = each.value
  value        = each.key == "SAF3AI_API_KEY" ? var.saf3ai_api_key : var.llm_api_key
  key_vault_id = azurerm_key_vault.kv.id
  tags         = local.tags

  depends_on = [azurerm_role_assignment.deployer_kv]
}

# ------------------------------------------------------------------ App Service
resource "azurerm_service_plan" "plan" {
  name                = var.plan_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = var.plan_sku
  tags                = local.tags
}

resource "azurerm_linux_web_app" "agent" {
  name                                           = var.app_name
  resource_group_name                            = azurerm_resource_group.rg.name
  location                                       = azurerm_resource_group.rg.location
  service_plan_id                                = azurerm_service_plan.plan.id
  https_only                                     = true
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  tags                                           = local.tags

  # Pulls the image and resolves Key Vault references (grants below)
  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                               = true
    container_registry_use_managed_identity = true
    health_check_path                       = "/healthz"
    health_check_eviction_time_in_min       = 5
    ip_restriction_default_action           = length(var.allowed_ip_ranges) > 0 ? "Deny" : "Allow"

    application_stack {
      docker_image_name   = "${var.image_name}:${var.image_tag}"
      docker_registry_url = "https://${local.acr_login_server}"
    }

    dynamic "ip_restriction" {
      for_each = var.allowed_ip_ranges
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 100 + ip_restriction.key
      }
    }
  }

  app_settings = merge(local.env, local.key_vault_refs, {
    # App Service routes traffic to WEBSITES_PORT (default 80). PORT is what the image binds to.
    WEBSITES_PORT                       = "8080"
    PORT                                = "8080"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
  })

  lifecycle {
    precondition {
      condition     = local.llm_key_env == "" || local.llm_key_set || var.llm_provider == "openai-compatible"
      error_message = "This llm_provider needs a key: set TF_VAR_llm_api_key."
    }
  }
}

# The system-assigned identity exists only after the app is created, so these
# grants land after its first start: restart the app once after the first apply.
resource "azurerm_role_assignment" "acr_pull" {
  scope                = local.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.agent.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "app_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User" # get secrets
  principal_id         = azurerm_linux_web_app.agent.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
