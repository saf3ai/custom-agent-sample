#!/usr/bin/env bash
# Stage the Saf3AI sample agent as a Hugging Face Docker Space.
#
#   bash prepare-space.sh                  -> stages into ./build/space (to inspect)
#   bash prepare-space.sh <SPACE_CLONE>    -> copies into your cloned Space repo (keeps its .git)
#
# Copies ../../agent (no .env files, no caches), then adds the Space config:
#   space/README.md  -> README.md   (its front-matter is the Space config: sdk docker, app_port 8080)
#   space/Dockerfile -> Dockerfile  (uid-1000 variant; agent/Dockerfile is not changed)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${AGENT_DIR:-$HERE/../../agent}" && pwd)"  # override: agent-variants/<framework>
DEFAULT_OUT="$HERE/build/space"
OUT="${1:-$DEFAULT_OUT}"

die() { echo "error: $*" >&2; exit 1; }

[ -f "$AGENT_DIR/app.py" ] || die "agent not found at $AGENT_DIR"

if [ -d "$OUT/.git" ]; then
  MODE=clone
elif [ "$OUT" = "$DEFAULT_OUT" ]; then
  MODE=staging
  rm -rf "$OUT"
elif [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  die "$OUT is not empty and is not a git clone of your Space"
else
  MODE=staging
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Agent sources, minus local secrets and caches
cd "$AGENT_DIR"
find . -type f \
  ! -path '*/__pycache__/*' ! -path './.venv/*' ! -path './venv/*' ! -name '*.pyc' \
  ! \( -name '.env' -o \( -name '.env.*' ! -name '.env.example' \) \) \
  -print | while IFS= read -r f; do
    mkdir -p "$OUT/$(dirname "$f")"
    cp "$f" "$OUT/$f"
  done

# Space config
cp "$HERE/space/README.md" "$OUT/README.md"
cp "$HERE/space/Dockerfile" "$OUT/Dockerfile"

# Guard: never push a .env file
if find "$OUT" -path "$OUT/.git" -prune -o \( -name '.env' -o \( -name '.env.*' ! -name '.env.example' \) \) -print | grep -q .; then
  die "a .env file is present in $OUT - remove it before pushing"
fi

echo "Staged Space files in: $OUT"
if [ "$MODE" = clone ]; then
  echo "Next:  cd \"$OUT\" && git add -A && git commit -m \"Deploy Saf3AI sample agent\" && git push"
else
  echo "Next:  clone your Space and re-run:  bash prepare-space.sh <SPACE_CLONE>"
fi
