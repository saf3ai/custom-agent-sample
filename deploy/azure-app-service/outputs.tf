output "app_url" {
  description = "Base URL of the agent (POST /chat, GET /healthz)."
  value       = "https://${azurerm_linux_web_app.agent.default_hostname}"
}

output "image" {
  description = "Image the app runs."
  value       = "${local.acr_login_server}/${var.image_name}:${var.image_tag}"
}

output "acr_login_server" {
  description = "Registry the app pulls from."
  value       = local.acr_login_server
}

output "key_vault_name" {
  description = "Key Vault holding the agent's secrets."
  value       = azurerm_key_vault.kv.name
}

output "principal_id" {
  description = "Object id of the app's system-assigned identity (AcrPull + Key Vault Secrets User)."
  value       = azurerm_linux_web_app.agent.identity[0].principal_id
}

output "restart_command" {
  description = "Run once after the first apply so the app picks up its new AcrPull and Key Vault grants."
  value       = "az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_linux_web_app.agent.name}"
}
