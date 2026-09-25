#!/usr/bin/env bash
# Deploy the Saf3AI sample agent to Google Cloud Run in one shot:
#   APIs -> Artifact Registry -> Cloud Build -> service account -> Secret Manager -> Cloud Run
# Re-runnable: existing resources are reused, a secret gets a new version only when
# its value changed, and every run deploys a new revision.
#
#   export SAF3AI_API_KEY='<SAF3AI_API_KEY>'
#   export LLM_API_KEY='<LLM_API_KEY>'          # only if LLM_PROVIDER needs a key
#   PROJECT_ID=<PROJECT_ID> LLM_PROVIDER=gemini ./deploy.sh
set -euo pipefail

# ================================================================ settings
# Override any of these from the environment.
PROJECT_ID="${PROJECT_ID:-}"                                 # required
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-saf3ai-sample-agent}"
AR_REPO="${AR_REPO:-saf3ai-agents}"                          # Artifact Registry repository
IMAGE_NAME="${IMAGE_NAME:-saf3ai-sample-agent}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"
RUNTIME_SA_NAME="${RUNTIME_SA_NAME:-saf3ai-sample-agent}"    # 6-30 chars
ALLOW_UNAUTHENTICATED="${ALLOW_UNAUTHENTICATED:-false}"      # true = public URL, no IAM auth
MIN_INSTANCES="${MIN_INSTANCES:-0}"                          # 0 = scale to zero
MAX_INSTANCES="${MAX_INSTANCES:-5}"
CONCURRENCY="${CONCURRENCY:-4}"                              # requests per instance; turns run one at a time per worker
CPU="${CPU:-1}"
MEMORY="${MEMORY:-1Gi}"

# Saf3AI
SAF3AI_COLLECTOR_AGENT="${SAF3AI_COLLECTOR_AGENT:-https://analyzer.saf3ai.com/v1/traces}"
SAF3AI_SCANNER_ENDPOINT="${SAF3AI_SCANNER_ENDPOINT:-https://scanner.saf3ai.com}"
SAF3AI_AGENT_ID="${SAF3AI_AGENT_ID:-sample-support-agent}"
SAF3AI_SERVICE_NAME="${SAF3AI_SERVICE_NAME:-$SAF3AI_AGENT_ID}"
SAF3AI_ENVIRONMENT="${SAF3AI_ENVIRONMENT:-production}"
SAF3AI_ENFORCEMENT="${SAF3AI_ENFORCEMENT:-block}"            # block | monitor
SAF3AI_FAIL_MODE="${SAF3AI_FAIL_MODE:-open}"                 # open | closed

# LLM
LLM_PROVIDER="${LLM_PROVIDER:-mock}"   # mock | gemini | vertex | anthropic | openai | azure-openai | huggingface | openai-compatible
LLM_MODEL="${LLM_MODEL:-}"             # blank = provider default (gemini, anthropic); required for the others
VERTEX_LOCATION="${VERTEX_LOCATION:-global}"
EXTRA_ENV_VARS="${EXTRA_ENV_VARS:-}"   # more KEY=VALUE pairs, '|'-separated, e.g. "OPENAI_BASE_URL=https://llm.example.com/v1"

# Secrets are read from the environment only: SAF3AI_API_KEY (required),
# LLM_API_KEY (when the provider needs a key).
# =========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/../../agent"
LABELS="app=saf3ai-sample-agent"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"
SA_EMAIL="${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

die() { echo "ERROR: $*" >&2; exit 1; }
gc() { gcloud --project="$PROJECT_ID" --quiet "$@"; }
retry() { # a new service account can take a moment to become usable in IAM bindings
  local attempt
  for attempt in 1 2 3 4 5; do
    "$@" && return 0
    echo "  retry $attempt/5 in 10s..."
    sleep 10
  done
  return 1
}

command -v gcloud >/dev/null || die "gcloud CLI not found"
[[ -n "$PROJECT_ID" ]] || die "set PROJECT_ID"
[[ -n "${SAF3AI_API_KEY:-}" ]] || die "export SAF3AI_API_KEY (Saf3AI console > Integrations > SDK > Custom Agent SDK)"
[[ -f "$AGENT_DIR/Dockerfile" ]] || die "agent/Dockerfile not found at $AGENT_DIR"

# Env var the chosen provider reads its key from (blank = no key)
case "$LLM_PROVIDER" in
  gemini) LLM_KEY_ENV=GEMINI_API_KEY ;;
  anthropic) LLM_KEY_ENV=ANTHROPIC_API_KEY ;;
  openai | openai-compatible) LLM_KEY_ENV=OPENAI_API_KEY ;;
  azure-openai) LLM_KEY_ENV=AZURE_OPENAI_API_KEY ;;
  huggingface) LLM_KEY_ENV=HF_TOKEN ;;
  vertex | mock) LLM_KEY_ENV="" ;;
  bedrock) die "bedrock needs AWS credentials - use an AWS target" ;;
  *) die "unknown LLM_PROVIDER '$LLM_PROVIDER'" ;;
esac
if [[ -n "$LLM_KEY_ENV" && -z "${LLM_API_KEY:-}" ]]; then
  # openai-compatible servers may not need a key
  [[ "$LLM_PROVIDER" == "openai-compatible" ]] || die "export LLM_API_KEY (passed to the agent as $LLM_KEY_ENV)"
  LLM_KEY_ENV=""
fi

echo "==> 1/6 Enabling APIs"
APIS=(run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
  secretmanager.googleapis.com iam.googleapis.com)
if [[ "$LLM_PROVIDER" == "vertex" ]]; then APIS+=(aiplatform.googleapis.com); fi
gc services enable "${APIS[@]}"

echo "==> 2/6 Artifact Registry repository: $AR_REPO ($REGION)"
if ! gc artifacts repositories describe "$AR_REPO" --location="$REGION" >/dev/null 2>&1; then
  gc artifacts repositories create "$AR_REPO" --location="$REGION" --repository-format=docker \
    --description="Saf3AI sample agent images" --labels="$LABELS"
fi

echo "==> 3/6 Building $IMAGE with Cloud Build"
# .dockerignore doubles as the upload filter, so a local agent/.env never leaves this machine
gc builds submit "$AGENT_DIR" --tag="$IMAGE" --ignore-file=.dockerignore

echo "==> 4/6 Runtime service account: $SA_EMAIL"
if ! gc iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  gc iam service-accounts create "$RUNTIME_SA_NAME" --display-name="Saf3AI sample agent (Cloud Run runtime)"
fi
if [[ "$LLM_PROVIDER" == "vertex" ]]; then
  retry gc projects add-iam-policy-binding "$PROJECT_ID" --condition=None \
    --member="serviceAccount:$SA_EMAIL" --role="roles/aiplatform.user" >/dev/null
fi

echo "==> 5/6 Secret Manager"
upsert_secret() { # <secret-id> <value>: create if missing, add a version if changed, grant the runtime SA read access
  local id="$1" value="$2"
  if ! gc secrets describe "$id" >/dev/null 2>&1; then
    gc secrets create "$id" --replication-policy=automatic --labels="$LABELS"
  fi
  if [[ "$(gc secrets versions access latest --secret="$id" 2>/dev/null || true)" != "$value" ]]; then
    printf '%s' "$value" | gc secrets versions add "$id" --data-file=-
  fi
  retry gc secrets add-iam-policy-binding "$id" \
    --member="serviceAccount:$SA_EMAIL" --role="roles/secretmanager.secretAccessor" >/dev/null
}
SAF3AI_SECRET="${SERVICE_NAME}-saf3ai-api-key"
upsert_secret "$SAF3AI_SECRET" "$SAF3AI_API_KEY"
SECRETS="SAF3AI_API_KEY=${SAF3AI_SECRET}:latest"
if [[ -n "$LLM_KEY_ENV" ]]; then
  LLM_SECRET="${SERVICE_NAME}-llm-api-key"
  upsert_secret "$LLM_SECRET" "$LLM_API_KEY"
  SECRETS+=",${LLM_KEY_ENV}=${LLM_SECRET}:latest"
fi

ENV_VARS="SAF3AI_COLLECTOR_AGENT=${SAF3AI_COLLECTOR_AGENT}"
ENV_VARS+="|SAF3AI_SCANNER_ENDPOINT=${SAF3AI_SCANNER_ENDPOINT}"
ENV_VARS+="|SAF3AI_AGENT_ID=${SAF3AI_AGENT_ID}"
ENV_VARS+="|SAF3AI_SERVICE_NAME=${SAF3AI_SERVICE_NAME}"
ENV_VARS+="|SAF3AI_ENVIRONMENT=${SAF3AI_ENVIRONMENT}"
ENV_VARS+="|SAF3AI_ENFORCEMENT=${SAF3AI_ENFORCEMENT}"
ENV_VARS+="|SAF3AI_FAIL_MODE=${SAF3AI_FAIL_MODE}"
ENV_VARS+="|LLM_PROVIDER=${LLM_PROVIDER}"
if [[ -n "$LLM_MODEL" ]]; then ENV_VARS+="|LLM_MODEL=${LLM_MODEL}"; fi
if [[ "$LLM_PROVIDER" == "vertex" ]]; then
  ENV_VARS+="|GOOGLE_CLOUD_PROJECT=${PROJECT_ID}|GOOGLE_CLOUD_LOCATION=${VERTEX_LOCATION}"
fi
if [[ -n "$EXTRA_ENV_VARS" ]]; then ENV_VARS+="|${EXTRA_ENV_VARS}"; fi

if [[ "$ALLOW_UNAUTHENTICATED" == "true" ]]; then
  AUTH_FLAG="--allow-unauthenticated"
else
  AUTH_FLAG="--no-allow-unauthenticated"
fi

echo "==> 6/6 Deploying Cloud Run service: $SERVICE_NAME"
# Cloud Run sets PORT from --port; ^|^ makes '|' the env-var separator (values may contain commas)
gc run deploy "$SERVICE_NAME" \
  --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$SA_EMAIL" \
  --port=8080 \
  --cpu="$CPU" \
  --memory="$MEMORY" \
  --min-instances="$MIN_INSTANCES" \
  --max-instances="$MAX_INSTANCES" \
  --concurrency="$CONCURRENCY" \
  --timeout=300 \
  --labels="$LABELS" \
  --set-env-vars="^|^${ENV_VARS}" \
  --set-secrets="$SECRETS" \
  "$AUTH_FLAG"

URL="$(gc run services describe "$SERVICE_NAME" --region="$REGION" --format='value(status.url)')"
cat <<EOF

Deployed: $URL
Test:
  curl -s -w '\\nHTTP %{http_code}\\n' "$URL/chat" \\
    -H "Authorization: Bearer \$(gcloud auth print-identity-token)" \\
    -H "Content-Type: application/json" -d '{"message":"Where is my order?"}'
EOF
