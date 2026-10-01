variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name for the ECR repository, secret, cluster, service, load balancer and roles."
  type        = string
  default     = "saf3ai-sample-agent"

  validation {
    condition     = length(var.name) <= 32
    error_message = "At most 32 characters (load balancer and target group name limit)."
  }
}

variable "image_tag" {
  description = "Image tag pushed by build-and-push.sh. terraform apply deploys the digest it points to."
  type        = string
  default     = "latest"
}

variable "vpc_id" {
  description = "VPC for the load balancer and the service."
  type        = string
}

variable "alb_subnet_ids" {
  description = "Subnets for the load balancer, in at least two Availability Zones (public subnets for an internet-facing ALB)."
  type        = list(string)
}

variable "service_subnet_ids" {
  description = "Subnets for the Fargate tasks. Need outbound HTTPS: private subnets with a NAT gateway, or public subnets with assign_public_ip = true."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Give tasks a public IP (only when service_subnet_ids are public subnets)."
  type        = bool
  default     = false
}

variable "internal_alb" {
  description = "true = internal load balancer (reachable from inside the VPC only)."
  type        = bool
  default     = false
}

variable "allowed_cidr_blocks" {
  description = "IPv4 CIDRs allowed to call the load balancer. Keep this to your callers."
  type        = list(string)
}

variable "certificate_arn" {
  description = "ACM certificate ARN. Set it to serve HTTPS on 443 (HTTP 80 then redirects). Empty = HTTP on 80 only."
  type        = string
  default     = ""
}

variable "dns_cidr_blocks" {
  description = "DNS resolvers allowed on task egress port 53. Empty = the VPC CIDR. The Amazon-provided resolver is not filtered by security groups."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = "Task vCPU units (256, 512, 1024, ...)."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory in MiB; must be valid for the chosen cpu."
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. Must match the image platform built by build-and-push.sh."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "desired_count" {
  description = "Number of tasks."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the agent's logs."
  type        = number
  default     = 30
}

variable "agent_env" {
  description = "Non-secret environment variables for the agent (see agent/.env.example). Keys and tokens go in the Secrets Manager secret. Do not set empty values."
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
}

variable "secret_keys" {
  description = "Keys of the secret JSON to inject as env vars. Every key listed must exist in the secret, or the task will not start."
  type        = list(string)
  default     = ["SAF3AI_API_KEY"]
}

variable "enable_bedrock" {
  description = "Grant the task role bedrock:InvokeModel (needed for LLM_PROVIDER=bedrock)."
  type        = bool
  default     = false
}

variable "bedrock_model_arns" {
  description = "Bedrock foundation-model / inference-profile ARNs the task may invoke. Empty = any foundation model or inference profile."
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
