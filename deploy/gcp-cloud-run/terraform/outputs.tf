output "service_url" {
  description = "Cloud Run URL. Call it with an identity token unless invoker_members includes allUsers."
  value       = google_cloud_run_v2_service.agent.uri
}

output "image" {
  description = "Image the service runs. Build it with: gcloud builds submit ../../../agent --ignore-file=.dockerignore --tag <image>"
  value       = local.image
}

output "runtime_service_account" {
  description = "Service account the agent runs as."
  value       = google_service_account.agent.email
}

output "secret_ids" {
  description = "Secret Manager secrets injected as env vars (env var => secret id)."
  value       = local.secrets
}
