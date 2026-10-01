output "function_name" {
  description = "Lambda function."
  value       = aws_lambda_function.agent.function_name
}

output "function_url" {
  description = "Function URL (ends with /)."
  value       = aws_lambda_function_url.agent.function_url
}

output "chat_url" {
  description = "Agent endpoint. With AWS_IAM, requests must be SigV4-signed (see README, Test)."
  value       = "${aws_lambda_function_url.agent.function_url}chat"
}

output "ecr_repository_url" {
  description = "Push the Lambda image here (build-and-push.sh does this)."
  value       = aws_ecr_repository.agent.repository_url
}

output "secret_name" {
  description = "Secrets Manager secret holding the agent's secret env vars as JSON."
  value       = aws_secretsmanager_secret.agent.name
}

output "log_group_name" {
  description = "CloudWatch log group with the function's logs."
  value       = aws_cloudwatch_log_group.agent.name
}
