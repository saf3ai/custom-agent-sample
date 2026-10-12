#!/bin/bash
# Build the CTF image and start the game on this EC2 instance.
# Settings come from SSM Parameter Store under /saf3ai-ctf/ (see ../ORGANISER-GUIDE.md, step 1.2).
#
#   usage: sudo bash start.sh <aws-region>
#
# Prints CTF_START_OK when the game answers, or CTF_START_FAILED with the reason.
set -u
REGION="${1:?usage: start.sh <aws-region>}"
ENV_FILE=/opt/ctf.env
cd "$(dirname "$0")/.." || exit 1          # the ctf/ folder

fail() { echo "CTF_START_FAILED: $1" >&2; exit 1; }
get() {
  aws ssm get-parameter --region "$REGION" --with-decryption --name "/saf3ai-ctf/$1" \
    --query Parameter.Value --output text
}

echo "== build the image"
docker build -t saf3ai-ctf . || fail "docker build"

echo "== read the settings"
umask 077
for name in SAF3AI_API_KEY CTF_ADMIN_TOKEN CTF_JOIN_CODE SAF3AI_AGENT_ID CTF_WORKERS LLM_MODEL; do
  value=$(get "$name") || fail "cannot read /saf3ai-ctf/$name in $REGION (step 1.2, and the role in step 1.3)"
  echo "$name=$value"
done > "$ENV_FILE"
{ echo "LLM_PROVIDER=bedrock"; echo "AWS_DEFAULT_REGION=$REGION"; } >> "$ENV_FILE"

echo "== start the game"
docker rm -f saf3ai-ctf > /dev/null 2>&1
docker run -d --name saf3ai-ctf --restart unless-stopped --env-file "$ENV_FILE" \
  -p 80:8080 -v saf3ai-ctf-data:/data saf3ai-ctf || fail "docker run"

for _ in $(seq 1 80); do      # the workers take a while to start
  curl -sf localhost/healthz > /dev/null && break
  sleep 3
done
if curl -sf localhost/healthz; then
  echo
  echo "CTF_START_OK"
else
  docker logs --tail 20 saf3ai-ctf
  fail "the game did not come up: the lines above say why"
fi
