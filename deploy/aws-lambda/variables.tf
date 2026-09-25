variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name for the ECR repository, secret, function and role."
  type        = string
  default     = "saf3ai-sample-agent"
}

variable "image_tag" {
  description = "Image tag pushed by build-and-push.sh. terraform apply deploys the digest it points to."
  type        = string
  default     = "latest"
}

variable "architecture" {
  description = "x86_64 or arm64. Must match PLATFORM in build-and-push.sh (linux/amd64 or linux/arm64)."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "memory_size" {
  description = "Function memory in MB (CPU scales with it)."
  type        = number
  default     = 1024
}

variable "timeout" {
  description = "Function timeout in seconds; covers one agent turn including the LLM call."
  type        = number
  default     = 60
}

variable "function_url_auth_type" {
  description = "AWS_IAM = callers sign requests with SigV4 and need lambda:InvokeFunctionUrl + lambda:InvokeFunction. NONE = public URL, anyone with it can call the agent."
  type        = string
  default     = "AWS_IAM"

  validation {
    condition     = contains(["AWS_IAM", "NONE"], var.function_url_auth_type)
    error_message = "function_url_auth_type must be AWS_IAM or NONE."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the function's logs."
  type        = number
  default     = 30
}

variable "agent_env" {
  description = "Non-secret environment variables for the agent (see agent/.env.example). Keys and tokens go in the Secrets Manager secret. Do not set empty values or AWS_REGION (Lambda sets it)."
  type        = map(string)
  default = {
    SAF3AI_COLLECTOR_AGENT  = "https://analyzer.saf3ai.com/v1/traces"
    SAF3AI_SCANNER_ENDPOINT = "https://scanner.saf3ai.com"
    SAF3AI_AGENT_ID         = "sample-support-agent"
    SAF3AI_SERVICE_NAME     = "sample-support-agent"
    SAF3AI_ENVIRONMENT      = "production"
    SAF3AI_ENFORCEMENT      = "block"
    SAF3AI_FAIL_MODE        = "open"
    LLM_PROVIDER            = "mock"
  }

  validation {
    condition     = !contains(keys(var.agent_env), "AWS_REGION")
    error_message = "Remove AWS_REGION: it is reserved and set by Lambda to the function's region."
  }
}

variable "enable_bedrock" {
  description = "Grant the function role bedrock:InvokeModel (needed for LLM_PROVIDER=bedrock)."
  type        = bool
  default     = false
}

variable "bedrock_model_arns" {
  description = "Bedrock foundation-model / inference-profile ARNs the function may invoke. Empty = any foundation model or inference profile."
  type        = list(string)
  default     = []
}

variable "secret_recovery_days" {
  description = "Days Secrets Manager keeps the secret after terraform destroy: 0 (delete immediately) or 7-30."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Extra tags for every resource. app = saf3ai-sample-agent is always added."
  type        = map(string)
  default     = {}
}
