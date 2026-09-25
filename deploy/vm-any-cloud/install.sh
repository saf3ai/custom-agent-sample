#!/usr/bin/env bash
# Install the Saf3AI sample agent as systemd service "saf3ai-agent" on an existing
# Linux VM (Ubuntu / Debian / Amazon Linux). Idempotent: safe to re-run.
# An existing /etc/saf3ai-agent/agent.env is never overwritten.
#
#   sudo IMAGE=<REGISTRY>/saf3ai-sample-agent:1.0.0 bash install.sh   # run an image you pushed
#   sudo AGENT_SRC=../../agent bash install.sh                         # or build it here from the kit
#
# Optional: HOST_PORT (default 8080).
set -euo pipefail

CONF_DIR=/etc/saf3ai-agent
ENV_FILE=$CONF_DIR/agent.env
UNIT_FILE=/etc/systemd/system/saf3ai-agent.service
IMAGE="${IMAGE:-}"
AGENT_SRC="${AGENT_SRC:-}"
HOST_PORT="${HOST_PORT:-8080}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ -n "$IMAGE" ] || [ -n "$AGENT_SRC" ] || die "set IMAGE=<registry>/saf3ai-sample-agent:<tag> or AGENT_SRC=<kit>/agent"

# 1. Docker
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y docker            # Amazon Linux 2023
  elif command -v yum >/dev/null 2>&1; then
    yum install -y docker            # Amazon Linux 2
  else
    die "install Docker Engine for this distro, then re-run"
  fi
fi
systemctl enable --now docker
DOCKER_BIN="$(command -v docker)"

# 2. Image: build locally, or pull on every service start
PULL_LINE="ExecStartPre=-$DOCKER_BIN pull \${IMAGE}"
if [ -n "$AGENT_SRC" ]; then
  [ -f "$AGENT_SRC/Dockerfile" ] || die "no Dockerfile in $AGENT_SRC"
  IMAGE="${IMAGE:-saf3ai-sample-agent:local}"
  log "Building $IMAGE from $AGENT_SRC"
  "$DOCKER_BIN" build -t "$IMAGE" "$AGENT_SRC"
  PULL_LINE="# local image - no pull"
fi

# 3. Settings file (created once, root-only)
install -d -m 0700 -o root -g root "$CONF_DIR"
if [ ! -f "$ENV_FILE" ]; then
  log "Writing $ENV_FILE - fill it in, then: systemctl restart saf3ai-agent"
  (
    umask 077
    cat > "$ENV_FILE" <<'EOF'
# docker --env-file format: KEY=value, no quotes, no empty values
SAF3AI_API_KEY=<SAF3AI_API_KEY>
SAF3AI_COLLECTOR_AGENT=https://analyzer.saf3ai.com/v1/traces
SAF3AI_SCANNER_ENDPOINT=https://scanner.saf3ai.com
SAF3AI_AGENT_ID=sample-support-agent
SAF3AI_SERVICE_NAME=sample-support-agent
SAF3AI_ENVIRONMENT=production
SAF3AI_ENFORCEMENT=block
SAF3AI_FAIL_MODE=open
# mock = no LLM key (smoke test). Options: see agent/.env.example in the kit.
LLM_PROVIDER=mock
# LLM_MODEL=<MODEL_ID>
# <PROVIDER_KEY_VAR>=<VALUE>
WEB_CONCURRENCY=1
EOF
  )
else
  log "Keeping existing $ENV_FILE"
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# 4. systemd unit (rewritten on each run with the current IMAGE)
log "Writing $UNIT_FILE (image: $IMAGE)"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Saf3AI sample agent (Docker)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Environment=IMAGE=$IMAGE
# Optional: refresh agent.env from your cloud secret store on every start (see README.md)
# ExecStartPre=-/bin/sh -c 'umask 077; <FETCH_COMMAND> > $ENV_FILE.tmp && mv $ENV_FILE.tmp $ENV_FILE'
ExecStartPre=-$DOCKER_BIN rm -f saf3ai-agent
$PULL_LINE
ExecStart=$DOCKER_BIN run --rm --name saf3ai-agent \\
  --env-file $ENV_FILE -p $HOST_PORT:8080 \\
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \\
  \${IMAGE}
ExecStop=$DOCKER_BIN stop saf3ai-agent
Restart=always
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$UNIT_FILE"

systemctl daemon-reload
systemctl enable saf3ai-agent
systemctl restart saf3ai-agent

# 5. Health check
if command -v curl >/dev/null 2>&1; then
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$HOST_PORT/healthz" >/dev/null 2>&1; then
      log "Healthy: http://127.0.0.1:$HOST_PORT/healthz"
      exit 0
    fi
    sleep 2
  done
  log "Not healthy yet - check: journalctl -u saf3ai-agent -n 100"
else
  log "Started. Check: systemctl status saf3ai-agent"
fi
