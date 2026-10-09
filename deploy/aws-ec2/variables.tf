variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name for the ECR repository, secret, IAM role, security group and instance."
  type        = string
  default     = "saf3ai-sample-agent"
}

variable "image_tag" {
  description = "Image tag pushed by build-and-push.sh."
  type        = string
  default     = "latest"
}

variable "vpc_id" {
  description = "VPC for the instance."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the instance. Needs outbound HTTPS: a NAT gateway, or a public subnet with associate_public_ip = true."
  type        = string
}

variable "associate_public_ip" {
  description = "Give the instance a public IP (public subnet only)."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "x86_64 instance type (build-and-push.sh builds linux/amd64)."
  type        = string
  default     = "t3.small"
}

variable "service_port" {
  description = "Port the agent is published on."
  type        = number
  default     = 8080
}

variable "allowed_cidr_blocks" {
  description = "IPv4 CIDRs allowed to call the agent on service_port. Keep this to your callers."
  type        = list(string)
}

variable "dns_cidr_blocks" {
  description = "DNS resolvers allowed on egress port 53. Empty = the VPC CIDR. The Amazon-provided resolver is not filtered by security groups."
  type        = list(string)
  default     = []
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

variable "enable_bedrock" {
  description = "Grant the instance role bedrock:InvokeModel (needed for LLM_PROVIDER=bedrock)."
  type        = bool
  default     = false
}

variable "bedrock_model_arns" {
  description = "Bedrock foundation-model / inference-profile ARNs the role may invoke. Empty = any foundation model or inference profile."
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
