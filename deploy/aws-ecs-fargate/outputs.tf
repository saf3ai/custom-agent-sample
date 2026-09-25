output "alb_dns_name" {
  description = "Load balancer DNS name. With certificate_arn set, point your certificate's DNS name at it."
  value       = aws_lb.agent.dns_name
}

output "chat_url" {
  description = "Agent endpoint through the load balancer."
  value       = local.https ? "https://${aws_lb.agent.dns_name}/chat" : "http://${aws_lb.agent.dns_name}/chat"
}

output "test_curl" {
  description = "Benign test request (HTTP listener). Expect HTTP 200 with a reply."
  value       = "curl -s http://${aws_lb.agent.dns_name}/chat -H 'Content-Type: application/json' -d '{\"message\":\"Where is my order 4211?\"}'"
}

output "ecr_repository_url" {
  description = "Push the agent image here (build-and-push.sh does this)."
  value       = aws_ecr_repository.agent.repository_url
}

output "secret_name" {
  description = "Secrets Manager secret holding the agent's secret env vars as JSON."
  value       = aws_secretsmanager_secret.agent.name
}

output "cluster_name" {
  description = "ECS cluster."
  value       = aws_ecs_cluster.agent.name
}

output "service_name" {
  description = "ECS service."
  value       = aws_ecs_service.agent.name
}

output "log_group_name" {
  description = "CloudWatch log group with the agent's logs."
  value       = aws_cloudwatch_log_group.agent.name
}
