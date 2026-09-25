#!/usr/bin/env bash
# Build the sample agent image (../../agent) in Azure Container Registry with
# ACR Tasks and push it there. No local Docker needed; needs the Azure CLI (az login).
set -euo pipefail

ACR_NAME="${ACR_NAME:-}"                         # = acr_name in terraform.tfvars
IMAGE_NAME="${IMAGE_NAME:-saf3ai-sample-agent}"  # = image_name in terraform.tfvars
IMAGE_TAG="${IMAGE_TAG:-v1}"                     # = image_tag in terraform.tfvars
PLATFORM="${PLATFORM:-linux/amd64}"
AGENT_DIR="$(cd "${AGENT_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../agent}" && pwd)"  # override: agent-variants/<framework>

command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found" >&2; exit 1; }
[[ -n "$ACR_NAME" ]] || { echo "ERROR: set ACR_NAME" >&2; exit 1; }

LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)"

# The build context honours agent/.dockerignore, so a local agent/.env is not uploaded
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --platform "$PLATFORM" \
  "$AGENT_DIR"

echo "Pushed ${LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
