# ------------------------------------------------------------------ project
variable "project_id" {
  description = "Google Cloud project to deploy into."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run and Artifact Registry, e.g. us-central1."
  type        = string
}

variable "labels" {
  description = "Extra labels for every resource that supports them (app = saf3ai-sample-agent is always added)."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------ names
variable "service_name" {
  description = "Cloud Run service name. Also prefixes the Secret Manager secret ids."
  type        = string
  default     = "saf3ai-sample-agent"
}

variable "artifact_repo_id" {
  description = "Artifact Registry (Docker) repository id."
  type        = string
  default     = "saf3ai-agents"
}

variable "image_name" {
  description = "Image name inside the repository."
  type        = string
  default     = "saf3ai-sample-agent"
}

variable "image_tag" {
  description = "Image tag you built with gcloud builds submit. Change it to roll out a new build."
  type        = string
  default     = "v1"
}

variable "runtime_sa_name" {
  description = "Account id of the dedicated runtime service account (6-30 chars)."
  type        = string
  default     = "saf3ai-sample-agent"
}

# ------------------------------------------------------------------ runtime
variable "cpu" {
  description = "vCPU per instance."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory per instance."
  type        = string
  default     = "1Gi"
}

variable "min_instances" {
  description = "Minimum instances. 0 = scale to zero (cold start on the first request after idle); 1 = always warm."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum instances."
  type        = number
  default     = 5
}

variable "max_request_concurrency" {
  description = "Concurrent requests per instance. The agent runs one turn at a time per worker process, so keep this low and let Cloud Run scale out."
  type        = number
  default     = 4
}

variable "invoker_members" {
  description = "Principals allowed to call the service, e.g. [\"user:you@example.com\", \"serviceAccount:caller@<PROJECT_ID>.iam.gserviceaccount.com\"]. [\"allUsers\"] makes it public."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------ Saf3AI
variable "saf3ai_api_key" {
  description = "Saf3AI organization API key (console > Integrations > SDK > Custom Agent SDK). Set with TF_VAR_saf3ai_api_key."
  type        = string
  sensitive   = true
}

variable "saf3ai_collector_agent" {
  description = "Saf3AI trace collector."
  type        = string
  default     = "https://analyzer.saf3ai.com/v1/traces"
}

variable "saf3ai_scanner_endpoint" {
  description = "Saf3AI scanner."
  type        = string
  default     = "https://scanner.saf3ai.com"
}

variable "saf3ai_agent_id" {
  description = "Agent id shown in the Saf3AI console."
  type        = string
  default     = "sample-support-agent"
}

variable "saf3ai_service_name" {
  description = "Service name in traces. Empty = saf3ai_agent_id."
  type        = string
  default     = ""
}

variable "saf3ai_environment" {
  description = "Environment label in traces, e.g. production, staging."
  type        = string
  default     = "production"
}

variable "saf3ai_enforcement" {
  description = "block = unsafe prompts get HTTP 403 before the LLM is called; monitor = allow and report."
  type        = string
  default     = "block"

  validation {
    condition     = contains(["block", "monitor"], var.saf3ai_enforcement)
    error_message = "saf3ai_enforcement must be block or monitor."
  }
}

variable "saf3ai_fail_mode" {
  description = "If the scanner cannot be reached: open = allow, closed = block."
  type        = string
  default     = "open"

  validation {
    condition     = contains(["open", "closed"], var.saf3ai_fail_mode)
    error_message = "saf3ai_fail_mode must be open or closed."
  }
}

# ------------------------------------------------------------------ LLM
variable "llm_provider" {
  description = "mock | gemini | vertex | anthropic | openai | azure-openai | huggingface | openai-compatible"
  type        = string
  default     = "mock"

  validation {
    condition     = contains(["mock", "gemini", "vertex", "anthropic", "openai", "azure-openai", "huggingface", "openai-compatible"], var.llm_provider)
    error_message = "Unsupported llm_provider for Cloud Run (bedrock needs AWS credentials - use an AWS target)."
  }
}

variable "llm_model" {
  description = "Model / deployment id. Empty = provider default (gemini, anthropic only)."
  type        = string
  default     = ""
}

variable "llm_api_key" {
  description = "Key for the chosen provider; stored in Secret Manager and passed as the provider's key variable. Not used for mock / vertex. Set with TF_VAR_llm_api_key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vertex_location" {
  description = "GOOGLE_CLOUD_LOCATION for llm_provider = vertex."
  type        = string
  default     = "global"
}

variable "extra_env" {
  description = "Extra non-secret env vars, e.g. { OPENAI_BASE_URL = \"https://llm.example.com/v1\", SAF3AI_BLOCK_RESPONSES = \"true\" }."
  type        = map(string)
  default     = {}
}
