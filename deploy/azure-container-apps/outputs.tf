output "app_url" {
  description = "Base URL of the agent (POST /chat, GET /healthz)."
  value       = "https://${azurerm_container_app.agent.ingress[0].fqdn}"
}

output "image" {
  description = "Image the app runs. Push it with build-and-push.sh."
  value       = local.image
}

output "acr_login_server" {
  description = "Registry the app pulls from."
  value       = local.acr_login_server
}

output "key_vault_name" {
  description = "Key Vault holding the agent's secrets."
  value       = azurerm_key_vault.kv.name
}

output "managed_identity_client_id" {
  description = "Client id of the app's user-assigned identity (AcrPull + Key Vault Secrets User)."
  value       = azurerm_user_assigned_identity.agent.client_id
}
