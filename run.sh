#!/usr/bin/env bash
# Launch Claude Code routed through LiteLLM Proxy → Portkey AI Gateway.
# LiteLLM translates Anthropic tool_use ↔ OpenAI function_call, enabling
# Claude Code's interactive agent mode with non-Claude models.
#
# Can be run from any directory — Claude Code opens in the caller's working dir.
# All Portkey/LiteLLM config is passed via env vars so the caller's
# project files and normal Anthropic login are never touched.
#
# Usage:
#   ~/Downloads/clawkey/run.sh                                # default model
#   ~/Downloads/clawkey/run.sh -C ~/my-project                # specify working dir
#   PORTKEY_MODEL=<model-name> ~/Downloads/clawkey/run.sh
#   ~/Downloads/clawkey/run.sh --print "explain this code"    # one-shot

set -euo pipefail

CLAWKEY_DIR="$(cd "$(dirname "$0")" && pwd)"
CALLER_DIR="$(pwd)"

# Parse -C <dir> option (must be first argument)
if [ "${1:-}" = "-C" ]; then
    if [ -z "${2:-}" ]; then
        echo "Error: -C requires a directory argument."
        exit 1
    fi
    CALLER_DIR="$(cd "$2" && pwd)"
    shift 2
fi

# Load environment
CLAWKEY_DIR="$CLAWKEY_DIR" source "${CLAWKEY_DIR}/load-env.sh"

# Activate venv if it exists (litellm is installed there)
if [ -d "${CLAWKEY_DIR}/.venv" ]; then
    source "${CLAWKEY_DIR}/.venv/bin/activate"
fi

# Verify litellm is available
if ! command -v litellm &>/dev/null; then
    echo "Error: litellm not found. Install it with: pip install 'litellm[proxy]'"
    exit 1
fi

MODEL="${PORTKEY_MODEL:-}"
MAX_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-16384}"
API_KEY="${AI_SANDBOX_KEY:-}"
LITELLM_PORT="${LITELLM_PORT:-4040}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-clawkey-local-$(date +%s)}"
LITELLM_PID=""

if [ -z "$MODEL" ]; then
    echo "Error: PORTKEY_MODEL is not set. Run: ./clawkey config"
    exit 1
fi

if [ -z "$API_KEY" ]; then
    echo "Error: AI_SANDBOX_KEY is not set. Run: ./clawkey config"
    exit 1
fi

export AI_SANDBOX_KEY="$API_KEY"
export LITELLM_MASTER_KEY

# Auth: use bearer token (skips onboarding prompt) and unset API key to
# avoid conflicts with the user's normal Anthropic login.
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
export ANTHROPIC_BASE_URL="http://localhost:${LITELLM_PORT}"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$MAX_TOKENS"
unset ANTHROPIC_API_KEY 2>/dev/null || true

cleanup() {
    if [ -n "$LITELLM_PID" ] && kill -0 "$LITELLM_PID" 2>/dev/null; then
        echo ""
        echo "Stopping LiteLLM proxy (PID $LITELLM_PID)..."
        kill "$LITELLM_PID" 2>/dev/null || true
        wait "$LITELLM_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Start LiteLLM proxy if not already running on the port
if curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
    echo "LiteLLM proxy already running on port ${LITELLM_PORT}."
else
    echo "Starting LiteLLM proxy on port ${LITELLM_PORT}..."
    litellm --config "${CLAWKEY_DIR}/litellm_config.yaml" --host 127.0.0.1 --port "$LITELLM_PORT" \
        > /tmp/litellm-clawkey.log 2>&1 &
    LITELLM_PID=$!

    # Wait for proxy to be ready (up to 30 seconds)
    echo -n "Waiting for proxy"
    for i in $(seq 1 30); do
        if curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
            echo " ready."
            break
        fi
        if ! kill -0 "$LITELLM_PID" 2>/dev/null; then
            echo ""
            echo "Error: LiteLLM proxy exited unexpectedly. Check /tmp/litellm-clawkey.log"
            cat /tmp/litellm-clawkey.log 2>/dev/null | tail -20
            exit 1
        fi
        echo -n "."
        sleep 1
    done

    if ! curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
        echo ""
        echo "Error: LiteLLM proxy failed to start within 30 seconds."
        echo "Log: /tmp/litellm-clawkey.log"
        cat /tmp/litellm-clawkey.log 2>/dev/null | tail -20
        exit 1
    fi
fi

echo ""
echo "Starting Claude Code via LiteLLM + Portkey..."
echo "  Model:      ${MODEL}"
echo "  Max tokens: ${MAX_TOKENS}"
echo "  Proxy:      http://localhost:${LITELLM_PORT}"
echo "  Gateway:    https://api.portkey.ai"
echo "  Directory:  ${CALLER_DIR}"
echo ""

# Launch Claude Code in the caller's working directory.
# All config is via env vars — no project files are modified.
cd "$CALLER_DIR"
claude --model "$MODEL" "$@"
