data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Resolves image_tag to its digest, so each push + terraform apply rolls out a new revision
data "aws_ecr_image" "agent" {
  repository_name = aws_ecr_repository.agent.name
  image_tag       = var.image_tag
}

locals {
  partition       = data.aws_partition.current.partition
  container_name  = "agent"
  container_port  = 8080
  https           = var.certificate_arn != ""
  listener_ports  = local.https ? [80, 443] : [80]
  dns_cidr_blocks = length(var.dns_cidr_blocks) > 0 ? var.dns_cidr_blocks : [data.aws_vpc.selected.cidr_block]

  environment = [
    for key, value in merge({ AWS_REGION = var.region }, var.agent_env) : { name = key, value = value }
  ]

  # ECS reads each key of the JSON secret: <secret-arn>:<json-key>::
  secrets = [
    for key in var.secret_keys : { name = key, valueFrom = "${aws_secretsmanager_secret.agent.arn}:${key}::" }
  ]

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
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by ECS to pull the image, write logs and read the secret
resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secret" {
  statement {
    sid       = "ReadAgentSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.agent.arn]
  }
}

resource "aws_iam_role_policy" "execution_secret" {
  name   = "${var.name}-read-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secret.json
}

# Task role: the identity the agent runs as (Bedrock calls use it)
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Bedrock Converse is authorised by bedrock:InvokeModel
data "aws_iam_policy_document" "bedrock" {
  statement {
    sid       = "BedrockInvoke"
    actions   = ["bedrock:InvokeModel"]
    resources = local.bedrock_resources
  }
}

resource "aws_iam_role_policy" "bedrock" {
  count = var.enable_bedrock ? 1 : 0

  name   = "${var.name}-bedrock"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.bedrock.json
}

# ---------------------------------------------------------------- Logs
resource "aws_cloudwatch_log_group" "agent" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- ECS
resource "aws_ecs_cluster" "agent" {
  name = var.name
}

resource "aws_ecs_task_definition" "agent" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name         = local.container_name
      image        = "${aws_ecr_repository.agent.repository_url}@${data.aws_ecr_image.agent.image_digest}"
      essential    = true
      portMappings = [{ containerPort = local.container_port, protocol = "tcp" }]
      environment  = local.environment
      secrets      = local.secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "agent"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "agent" {
  name                              = var.name
  cluster                           = aws_ecs_cluster.agent.id
  task_definition                   = aws_ecs_task_definition.agent.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.service_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.agent.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_iam_role_policy.execution_secret,
  ]
}

# ---------------------------------------------------------------- Load balancer
resource "aws_lb" "agent" {
  name                       = var.name
  internal                   = var.internal_alb
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.alb_subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "agent" {
  name                 = var.name
  port                 = local.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTP: forwards to the agent, or redirects to HTTPS when certificate_arn is set
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.agent.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https ? "redirect" : "forward"
    target_group_arn = local.https ? null : aws_lb_target_group.agent.arn

    dynamic "redirect" {
      for_each = local.https ? [1] : []

      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https ? 1 : 0

  load_balancer_arn = aws_lb.agent.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }
}

# ---------------------------------------------------------------- Security groups
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Saf3AI sample agent ALB: listener ports from allowed CIDRs"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { for pair in setproduct(var.allowed_cidr_blocks, local.listener_ports) : "${pair[0]}-${pair[1]}" => pair }

  security_group_id = aws_security_group.alb.id
  description       = "Callers"
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To agent tasks"
  referenced_security_group_id = aws_security_group.service.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

resource "aws_security_group" "service" {
  name        = "${var.name}-service"
  description = "Saf3AI sample agent tasks: agent port from the ALB; HTTPS and DNS out"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "From the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

resource "aws_vpc_security_group_egress_rule" "service_https" {
  security_group_id = aws_security_group.service.id
  description       = "HTTPS: Saf3AI, LLM provider, ECR, Secrets Manager, CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "service_dns" {
  for_each = { for pair in setproduct(local.dns_cidr_blocks, ["udp", "tcp"]) : "${pair[0]}-${pair[1]}" => pair }

  security_group_id = aws_security_group.service.id
  description       = "DNS"
  cidr_ipv4         = each.value[0]
  ip_protocol       = each.value[1]
  from_port         = 53
  to_port           = 53
}
