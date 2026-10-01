locals {
  labels    = merge(var.labels, { app = "saf3ai-sample-agent" })
  is_vertex = var.llm_provider == "vertex"
  image     = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.agent.repository_id}/${var.image_name}:${var.image_tag}"

  # Env var each provider reads its key from (mock / vertex need none)
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

  # env var name => Secret Manager secret id (names only, no values)
  secrets = {
    for name in compact(["SAF3AI_API_KEY", local.llm_key_set ? local.llm_key_env : ""]) :
    name => "${var.service_name}-${name == "SAF3AI_API_KEY" ? "saf3ai-api-key" : "llm-api-key"}"
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
        GOOGLE_CLOUD_PROJECT    = local.is_vertex ? var.project_id : ""
        GOOGLE_CLOUD_LOCATION   = local.is_vertex ? var.vertex_location : ""
      },
      var.extra_env,
    ) : k => v if v != ""
  }
}

# ------------------------------------------------------------------ APIs
resource "google_project_service" "apis" {
  for_each = toset(concat(
    [
      "run.googleapis.com",
      "artifactregistry.googleapis.com",
      "cloudbuild.googleapis.com",
      "secretmanager.googleapis.com",
      "iam.googleapis.com",
    ],
    local.is_vertex ? ["aiplatform.googleapis.com"] : [],
  ))

  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------ image registry
resource "google_artifact_registry_repository" "agent" {
  location      = var.region
  repository_id = var.artifact_repo_id
  format        = "DOCKER"
  description   = "Saf3AI sample agent images"
  labels        = local.labels

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------ runtime identity
resource "google_service_account" "agent" {
  account_id   = var.runtime_sa_name
  display_name = "Saf3AI sample agent (Cloud Run runtime)"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "vertex_user" {
  count = local.is_vertex ? 1 : 0

  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agent.email}"
}

# ------------------------------------------------------------------ secrets
resource "google_secret_manager_secret" "agent" {
  for_each = local.secrets

  secret_id = each.value
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# Values come from sensitive variables; they are stored in Terraform state
resource "google_secret_manager_secret_version" "agent" {
  for_each = local.secrets

  secret      = google_secret_manager_secret.agent[each.key].id
  secret_data = each.key == "SAF3AI_API_KEY" ? var.saf3ai_api_key : var.llm_api_key
}

# Read access on these secrets only
resource "google_secret_manager_secret_iam_member" "agent" {
  for_each = local.secrets

  project   = google_secret_manager_secret.agent[each.key].project
  secret_id = google_secret_manager_secret.agent[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent.email}"
}

# ------------------------------------------------------------------ Cloud Run
resource "google_cloud_run_v2_service" "agent" {
  name                = var.service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false # allow terraform destroy
  labels              = local.labels

  template {
    service_account                  = google_service_account.agent.email
    max_instance_request_concurrency = var.max_request_concurrency
    timeout                          = "300s"
    labels                           = local.labels

    scaling {
      min_instance_count = var.min_instances # 0 = scale to zero
      max_instance_count = var.max_instances
    }

    containers {
      image = local.image

      # Cloud Run sets PORT to this value; the image listens on $PORT
      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true # CPU billed only while serving requests
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = local.env
        content {
          name  = env.key
          value = env.value
        }
      }

      # Pinned to the version Terraform wrote, so rotating a key rolls out a new revision
      dynamic "env" {
        for_each = local.secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.agent[env.key].secret_id
              version = google_secret_manager_secret_version.agent[env.key].version
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        initial_delay_seconds = 0
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 12
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
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
    google_secret_manager_secret_version.agent,
    google_secret_manager_secret_iam_member.agent,
    google_project_iam_member.vertex_user,
  ]
}

# Callers need roles/run.invoker (the service is private unless allUsers is listed)
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = toset(var.invoker_members)

  project  = google_cloud_run_v2_service.agent.project
  location = google_cloud_run_v2_service.agent.location
  name     = google_cloud_run_v2_service.agent.name
  role     = "roles/run.invoker"
  member   = each.value
}
