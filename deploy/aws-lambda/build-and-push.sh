#!/usr/bin/env bash
# Build the agent image (../../agent), layer the Lambda Web Adapter on top
# (./Dockerfile) and push the result to the ECR repository created by Terraform.
# Needs Docker with its default builder (it reads the local agent image) and the AWS CLI v2.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"              # = region in terraform.tfvars
REPO_NAME="${REPO_NAME:-saf3ai-sample-agent}"  # = name in terraform.tfvars
IMAGE_TAG="${IMAGE_TAG:-latest}"               # = image_tag in terraform.tfvars
PLATFORM="${PLATFORM:-linux/amd64}"            # linux/arm64 for architecture = "arm64"
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(cd "$HERE/../../agent" && pwd)"
AGENT_IMAGE="saf3ai-sample-agent:$IMAGE_TAG"

REPO_URL="$(aws ecr describe-repositories --region "$REGION" --repository-names "$REPO_NAME" \
  --query 'repositories[0].repositoryUri' --output text)"
REGISTRY="${REPO_URL%%/*}"

# 1. The agent image, unchanged
docker build --platform "$PLATFORM" -t "$AGENT_IMAGE" "$AGENT_DIR"

# 2. + Lambda Web Adapter. --provenance=false keeps a single-image manifest, which Lambda requires.
docker build --platform "$PLATFORM" --provenance=false \
  --build-arg AGENT_IMAGE="$AGENT_IMAGE" \
  -t "$REPO_URL:$IMAGE_TAG" - < "$HERE/Dockerfile"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
docker push "$REPO_URL:$IMAGE_TAG"

echo "Pushed $REPO_URL:$IMAGE_TAG - run terraform apply to deploy it"
