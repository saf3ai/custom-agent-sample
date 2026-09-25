output "instance_id" {
  description = "EC2 instance id (Session Manager target)."
  value       = aws_instance.agent.id
}

output "private_ip" {
  description = "Private IP of the instance."
  value       = aws_instance.agent.private_ip
}

output "public_ip" {
  description = "Public IP of the instance (empty when associate_public_ip = false)."
  value       = aws_instance.agent.public_ip
}

output "ecr_repository_url" {
  description = "Push the agent image here (build-and-push.sh does this)."
  value       = aws_ecr_repository.agent.repository_url
}

output "secret_name" {
  description = "Secrets Manager secret holding the agent's secret env vars as JSON."
  value       = aws_secretsmanager_secret.agent.name
}

output "chat_url" {
  description = "Agent endpoint (public IP if any, else private IP)."
  value       = "http://${local.endpoint_ip}:${var.service_port}/chat"
}

output "test_curl" {
  description = "Benign test request. Expect HTTP 200 with a reply."
  value       = "curl -s http://${local.endpoint_ip}:${var.service_port}/chat -H 'Content-Type: application/json' -d '{\"message\":\"Where is my order 4211?\"}'"
}

output "ssm_port_forward" {
  description = "Tunnel the agent port to localhost:8080 when the instance has no route from your machine."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.agent.id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"${var.service_port}\"],\"localPortNumber\":[\"8080\"]}'"
}
