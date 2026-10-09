data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Latest Amazon Linux 2023 (x86_64) AMI, published by AWS in SSM Parameter Store
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  partition       = data.aws_partition.current.partition
  image_uri       = "${aws_ecr_repository.agent.repository_url}:${var.image_tag}"
  registry        = split("/", aws_ecr_repository.agent.repository_url)[0]
  container_env   = merge({ AWS_REGION = var.region }, var.agent_env)
  dns_cidr_blocks = length(var.dns_cidr_blocks) > 0 ? var.dns_cidr_blocks : [data.aws_vpc.selected.cidr_block]
  endpoint_ip     = coalesce(aws_instance.agent.public_ip, aws_instance.agent.private_ip)

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
# so keys never enter Terraform state. See README, Deploy step 3.
resource "aws_secretsmanager_secret" "agent" {
  name                    = var.name
  description             = "Secret env vars for ${var.name} as JSON, e.g. {\"SAF3AI_API_KEY\": \"...\"}"
  recovery_window_in_days = var.secret_recovery_days
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager: shell and port forwarding without SSH keys or port 22
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "agent" {
  statement {
    sid       = "ReadAgentSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.agent.arn]
  }

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
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

resource "aws_iam_instance_profile" "agent" {
  name = "${var.name}-ec2"
  role = aws_iam_role.agent.name
}

# ---------------------------------------------------------------- Network
resource "aws_security_group" "agent" {
  name        = "${var.name}-ec2"
  description = "Saf3AI sample agent: service port in; HTTPS and DNS out"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "service" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.agent.id
  description       = "Agent service port"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.service_port
  to_port           = var.service_port
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.agent.id
  description       = "HTTPS: Saf3AI, LLM provider, ECR, Secrets Manager, SSM, OS packages"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each = { for pair in setproduct(local.dns_cidr_blocks, ["udp", "tcp"]) : "${pair[0]}-${pair[1]}" => pair }

  security_group_id = aws_security_group.agent.id
  description       = "DNS"
  cidr_ipv4         = each.value[0]
  ip_protocol       = each.value[1]
  from_port         = 53
  to_port           = 53
}

# ---------------------------------------------------------------- Instance
resource "aws_instance" "agent" {
  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.agent.id]
  iam_instance_profile        = aws_iam_instance_profile.agent.name
  associate_public_ip_address = var.associate_public_ip
  user_data_replace_on_change = true # new agent_env / image_tag = new instance

  # No secrets here: user data is plain text. It fetches the secret at boot.
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region       = var.region
    secret_arn   = aws_secretsmanager_secret.agent.arn
    image_uri    = local.image_uri
    registry     = local.registry
    service_port = var.service_port
    agent_env    = local.container_env
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # lets the container reach IMDSv2 for role credentials (Bedrock)
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = var.name
  }

  lifecycle {
    ignore_changes = [ami] # a newer AL2023 release does not replace a running instance
  }

  depends_on = [
    aws_iam_role_policy.agent,
    aws_iam_role_policy_attachment.ssm,
  ]
}
