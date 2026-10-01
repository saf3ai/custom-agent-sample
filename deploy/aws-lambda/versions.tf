terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28" # 6.28+ has invoked_via_function_url (needed for public Function URLs)
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(var.tags, { app = "saf3ai-sample-agent" })
  }
}
