data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

# Resolves image_tag to its digest, so each push + terraform apply deploys the new image
data "aws_ecr_image" "agent" {
  repository_name = aws_ecr_repository.agent.name
  image_tag       = var.image_tag
}

locals {
  partition  = data.aws_partition.current.partition
  public_url = var.function_url_auth_type == "NONE"

  bedrock_resources = length(var.bedrock_model_arns) > 0 ? var.bedrock_model_arns : [
    "arn:${local.partition}:bedrock:*::foundation-model/*",
    "arn:${local.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
  ]
}

# ---------------------------------------------------------------- Image registry
resource "aws_ecr_repository" "agent" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # terraform destroy also deletes the pushed images

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------- Secret
# Created empty. The value (a JSON of secret env vars) is set with the AWS CLI,
# so keys never enter Terraform state. The image's launcher reads it at cold
# start (see Dockerfile), so it is not in the function configuration either.
resource "aws_secretsmanager_secret" "agent" {
  name                    = var.name
  description             = "Secret env vars for ${var.name} as JSON, e.g. {\"SAF3AI_API_KEY\": \"...\"}"
  recovery_window_in_days = var.secret_recovery_days
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "agent" {
  statement {
    sid       = "ReadAgentSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.agent.arn]
  }

  # Same-account image pull is granted on the role, so no repository policy is needed
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.agent.arn]
  }

  # Bedrock Converse is authorised by bedrock:InvokeModel
  dynamic "statement" {
    for_each = var.enable_bedrock ? [1] : []

    content {
      sid       = "BedrockInvoke"
      actions   = ["bedrock:InvokeModel"]
      resources = local.bedrock_resources
    }
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "${var.name}-agent"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

# ---------------------------------------------------------------- Function
resource "aws_cloudwatch_log_group" "agent" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "agent" {
  function_name = var.name
  role          = aws_iam_role.agent.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.agent.repository_url}@${data.aws_ecr_image.agent.image_digest}"
  architectures = [var.architecture]
  memory_size   = var.memory_size
  timeout       = var.timeout

  environment {
    variables = merge(var.agent_env, {
      SAF3AI_SECRET_ID = aws_secretsmanager_secret.agent.arn # read by the launcher at cold start
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.agent,
    aws_iam_role_policy.agent,
    aws_iam_role_policy_attachment.logs,
  ]
}

resource "aws_lambda_function_url" "agent" {
  function_name      = aws_lambda_function.agent.function_name
  authorization_type = var.function_url_auth_type
}

# NONE only: the resource policy that makes the URL public. Both statements are
# required for Function URLs; the second is limited to calls through the URL.
resource "aws_lambda_permission" "url_public" {
  count = local.public_url ? 1 : 0

  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.agent.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_public_invoke" {
  count = local.public_url ? 1 : 0

  statement_id             = "FunctionURLInvokeAllowPublicAccess"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.agent.function_name
  principal                = "*"
  invoked_via_function_url = true
}
