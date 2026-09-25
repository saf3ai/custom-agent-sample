data "azurerm_client_config" "current" {}

locals {
  tags = merge(var.tags, { app = "saf3ai-sample-agent" })

  # New registry, or an existing one that already holds the image
  acr_id           = coalesce(one(azurerm_container_registry.acr[*].id), one(data.azurerm_container_registry.existing[*].id))
  acr_login_server = coalesce(one(azurerm_container_registry.acr[*].login_server), one(data.azurerm_container_registry.existing[*].login_server))
  image            = "${local.acr_login_server}/${var.image_name}:${var.image_tag}"

  # Env var each provider reads its key from (mock needs none)
  provider_key_env = {
    gemini              = "GEMINI_API_KEY"
    anthropic           = "ANTHROPIC_API_KEY"
    openai              = "OPENAI_API_KEY"
    "azure-openai"      = "AZURE_OPENAI_API_KEY"
    huggingface         = "HF_TOKEN"
    "openai-compatible" = "OPENAI_API_KEY"
  }
  llm_key_env = lookup(local.provider_key_env, var.llm_provider, "")
  llm_key_set = nonsensitive(var.llm_api_key != "")

  # env var name => Key Vault / Container App secret name (names only, no values)
  secrets = {
    for name in compact(["SAF3AI_API_KEY", local.llm_key_set ? local.llm_key_env : ""]) :
    name => name == "SAF3AI_API_KEY" ? "saf3ai-api-key" : "llm-api-key"
  }

  # Plain env vars; empty values are dropped so the agent's own defaults apply
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

# ------------------------------------------------------------------ identity
resource "azurerm_user_assigned_identity" "agent" {
  name                = "${var.app_name}-id"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = local.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
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

# Lets the app identity read them
resource "azurerm_role_assignment" "app_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
  principal_type       = "ServicePrincipal"
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

# ------------------------------------------------------------------ environment
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "${var.app_name}-logs"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_app_environment" "env" {
  name                       = var.environment_name
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  tags                       = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# ------------------------------------------------------------------ app
resource "azurerm_container_app" "agent" {
  name                         = var.app_name
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent.id]
  }

  registry {
    server   = local.acr_login_server
    identity = azurerm_user_assigned_identity.agent.id
  }

  # Key Vault references, read with the managed identity. Versionless ids pick up rotations.
  dynamic "secret" {
    for_each = local.secrets
    content {
      name                = secret.value
      identity            = azurerm_user_assigned_identity.agent.id
      key_vault_secret_id = azurerm_key_vault_secret.agent[secret.key].versionless_id
    }
  }

  ingress {
    external_enabled = var.external_ingress
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }

    dynamic "ip_security_restriction" {
      for_each = var.allowed_ip_ranges
      content {
        name             = "allow-${ip_security_restriction.key}"
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
      }
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = tostring(var.scale_concurrent_requests)
    }

    container {
      name   = "agent"
      image  = local.image
      cpu    = var.cpu
      memory = var.memory

      dynamic "env" {
        for_each = local.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secrets
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/healthz"
        interval_seconds        = 5
        timeout                 = 3
        failure_count_threshold = 12
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/healthz"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/healthz"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.llm_key_env == "" || local.llm_key_set || var.llm_provider == "openai-compatible"
      error_message = "This llm_provider needs a key: set TF_VAR_llm_api_key."
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.app_kv,
  ]
}
