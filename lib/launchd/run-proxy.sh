#!/usr/bin/env bash
# run-proxy.sh — invoked by launchd to start the LiteLLM proxy.
# Reads CLAWKEY_DIR and LITELLM_PORT from the launchd EnvironmentVariables block.
# Sources .env (for AI_SANDBOX_KEY, LITELLM_MASTER_KEY) and activates the venv
# if one exists, then execs litellm. All output goes to launchd-managed
# StandardOutPath / StandardErrorPath.

set -euo pipefail

if [ -z "${CLAWKEY_DIR:-}" ]; then
    echo "Error: CLAWKEY_DIR not set in launchd EnvironmentVariables" >&2
    exit 64
fi

if [ ! -d "$CLAWKEY_DIR" ]; then
    echo "Error: CLAWKEY_DIR=${CLAWKEY_DIR} does not exist" >&2
    exit 64
fi

cd "$CLAWKEY_DIR"

CONFIG_DIR="${CLAWKEY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/clawkey}"
ENV_FILE="$CONFIG_DIR/.env"
LITELLM_CONFIG="$CONFIG_DIR/litellm_config.yaml"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ENV_FILE"
    set +a
fi

if [ ! -f "$LITELLM_CONFIG" ]; then
    echo "Error: $LITELLM_CONFIG not found. Run: clawkey config" >&2
    exit 64
fi

if [ -d "$CLAWKEY_DIR/.venv" ]; then
    # shellcheck disable=SC1091
    . "$CLAWKEY_DIR/.venv/bin/activate"
fi

if ! command -v litellm >/dev/null 2>&1; then
    echo "Error: litellm not on PATH after sourcing venv" >&2
    exit 127
fi

PORT="${LITELLM_PORT:-4040}"

exec litellm \
    --config "$LITELLM_CONFIG" \
    --host 127.0.0.1 \
    --port "$PORT"
