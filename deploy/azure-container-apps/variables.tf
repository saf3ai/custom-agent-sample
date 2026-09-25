# ------------------------------------------------------------------ placement
variable "location" {
  description = "Azure region, e.g. eastus, westeurope, centralindia."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create."
  type        = string
  default     = "rg-saf3ai-sample-agent"
}

variable "environment_name" {
  description = "Container Apps environment name."
  type        = string
  default     = "cae-saf3ai-sample-agent"
}

variable "app_name" {
  description = "Container App name (lowercase letters, digits, hyphens; max 32). Also prefixes the identity and Log Analytics workspace."
  type        = string
  default     = "saf3ai-sample-agent"
}

variable "tags" {
  description = "Extra tags (app = saf3ai-sample-agent is always added)."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------ image
variable "create_acr" {
  description = "true = create a new Azure Container Registry named acr_name. false = use an existing registry acr_name that already holds the image."
  type        = bool
  default     = true
}

variable "acr_name" {
  description = "Registry name, globally unique, 5-50 letters/digits."
  type        = string
}

variable "acr_resource_group_name" {
  description = "Resource group of the existing registry (create_acr = false). Empty = resource_group_name."
  type        = string
  default     = ""
}

variable "image_name" {
  description = "Image repository in the registry."
  type        = string
  default     = "saf3ai-sample-agent"
}

variable "image_tag" {
  description = "Image tag pushed by build-and-push.sh. Use a new tag for every build so a new revision rolls out."
  type        = string
  default     = "v1"
}

# ------------------------------------------------------------------ secrets
variable "key_vault_name" {
  description = "Key Vault name, globally unique, 3-24 letters/digits/hyphens."
  type        = string
}

# ------------------------------------------------------------------ runtime
variable "cpu" {
  description = "vCPU per replica (must pair with memory, e.g. 0.5 / 1Gi, 1 / 2Gi)."
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "Memory per replica."
  type        = string
  default     = "1Gi"
}

variable "min_replicas" {
  description = "0 = scale to zero (cold start on the first request after idle); 1 = always warm."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas."
  type        = number
  default     = 5
}

variable "scale_concurrent_requests" {
  description = "Concurrent requests per replica before scaling out. The agent runs one turn at a time per worker process, so keep this low."
  type        = number
  default     = 4
}

variable "external_ingress" {
  description = "true = public HTTPS endpoint; false = reachable only inside the Container Apps environment."
  type        = bool
  default     = true
}

variable "allowed_ip_ranges" {
  description = "CIDRs allowed to call the app, e.g. [\"203.0.113.0/24\"]. Empty = any caller. /chat has no authentication of its own."
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
  description = "mock | gemini | anthropic | openai | azure-openai | huggingface | openai-compatible"
  type        = string
  default     = "mock"

  validation {
    condition     = contains(["mock", "gemini", "google-genai", "anthropic", "openai", "azure-openai", "huggingface", "openai-compatible"], var.llm_provider)
    error_message = "Unsupported llm_provider on Azure (vertex needs Google credentials, bedrock needs AWS credentials)."
  }
}

variable "llm_model" {
  description = "Model id, or the deployment name for azure-openai. Empty = provider default (gemini, anthropic only)."
  type        = string
  default     = ""
}

variable "llm_api_key" {
  description = "Key for the chosen provider; stored in Key Vault and passed as the provider's key variable. Not used for mock. Set with TF_VAR_llm_api_key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "extra_env" {
  description = "Extra non-secret env vars, e.g. { AZURE_OPENAI_ENDPOINT = \"https://<RESOURCE>.openai.azure.com\", AZURE_OPENAI_API_VERSION = \"2024-10-21\" }."
  type        = map(string)
  default     = {}
}

variable "llm_key_env" {
  description = "Env var the agent reads the LLM key from. Blank = derived from llm_provider. Set it for agent-variants, e.g. GOOGLE_API_KEY."
  type        = string
  default     = ""
}
