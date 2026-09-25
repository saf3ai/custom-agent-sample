#!/usr/bin/env bash
# Build the sample agent image (../../agent) and push it to the ECR repository
# created by Terraform. Run from anywhere; needs Docker and the AWS CLI v2.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"              # = region in terraform.tfvars
REPO_NAME="${REPO_NAME:-saf3ai-sample-agent}"  # = name in terraform.tfvars
IMAGE_TAG="${IMAGE_TAG:-latest}"               # = image_tag in terraform.tfvars
PLATFORM="${PLATFORM:-linux/amd64}"            # X86_64 tasks; linux/arm64 for cpu_architecture = "ARM64"
AGENT_DIR="$(cd "$(dirname "$0")/../../agent" && pwd)"

REPO_URL="$(aws ecr describe-repositories --region "$REGION" --repository-names "$REPO_NAME" \
  --query 'repositories[0].repositoryUri' --output text)"
REGISTRY="${REPO_URL%%/*}"

docker build --platform "$PLATFORM" -t "saf3ai-sample-agent:$IMAGE_TAG" "$AGENT_DIR"
docker tag "saf3ai-sample-agent:$IMAGE_TAG" "$REPO_URL:$IMAGE_TAG"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
docker push "$REPO_URL:$IMAGE_TAG"

echo "Pushed $REPO_URL:$IMAGE_TAG"
