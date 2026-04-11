#!/usr/bin/env bash
# Launch Ralph orchestrator with swappable backend (claude or aider).
#
# CLAWKEY_BACKEND=claude (default):
#   Starts LiteLLM proxy, sets Anthropic env vars, runs Ralph.
#   Ralph → portkey-backend.sh → claude --print → LiteLLM → Portkey → LLM
#
# CLAWKEY_BACKEND=aider:
#   Sets OpenAI env vars pointing at Portkey directly, runs Ralph.
#   Ralph → portkey-backend.sh → aider --message → Portkey → LLM
#
# Usage:
#   ~/Downloads/clawkey/ralph-run.sh                              # claude backend
#   CLAWKEY_BACKEND=aider ~/Downloads/clawkey/ralph-run.sh        # aider backend
#   PORTKEY_MODEL=gemini-3.1-pro-preview ~/Downloads/clawkey/ralph-run.sh

set -euo pipefail

CLAWKEY_DIR="$(cd "$(dirname "$0")" && pwd)"
CALLER_DIR="$(pwd)"

# Load environment
source "${CLAWKEY_DIR}/setup-env.sh"

BACKEND="${CLAWKEY_BACKEND:-claude}"
MODEL="${PORTKEY_MODEL:-gemini-3.1-pro-preview}"
API_KEY="${AI_SANDBOX_KEY:-}"
LITELLM_PORT="${LITELLM_PORT:-4040}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-clawkey-local-$(date +%s)}"
LITELLM_PID=""

if [ -z "$API_KEY" ]; then
    echo "Error: AI_SANDBOX_KEY is not set. Run: source setup-env.sh"
    exit 1
fi

# Verify ralph is available
if ! command -v ralph &>/dev/null; then
    echo "Error: ralph not found. Install Ralph orchestrator first."
    exit 1
fi

# Verify ralph.yml exists (check caller dir first, then clawkey dir)
if [ -f "${CALLER_DIR}/ralph.yml" ]; then
    RALPH_CONFIG="${CALLER_DIR}/ralph.yml"
elif [ -f "${CLAWKEY_DIR}/ralph.yml" ]; then
    RALPH_CONFIG="${CLAWKEY_DIR}/ralph.yml"
else
    echo "Error: ralph.yml not found in ${CALLER_DIR} or ${CLAWKEY_DIR}"
    exit 1
fi

export AI_SANDBOX_KEY="$API_KEY"
export CLAWKEY_BACKEND="$BACKEND"
export PORTKEY_MODEL="$MODEL"

cleanup() {
    if [ -n "$LITELLM_PID" ] && kill -0 "$LITELLM_PID" 2>/dev/null; then
        echo ""
        echo "Stopping LiteLLM proxy (PID $LITELLM_PID)..."
        kill "$LITELLM_PID" 2>/dev/null || true
        wait "$LITELLM_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

if [ "$BACKEND" = "claude" ]; then
    # Activate venv if it exists (litellm is installed there)
    if [ -d "${CLAWKEY_DIR}/.venv" ]; then
        source "${CLAWKEY_DIR}/.venv/bin/activate"
    fi

    # Verify litellm is available
    if ! command -v litellm &>/dev/null; then
        echo "Error: litellm not found. Install it with: pip install 'litellm[proxy]'"
        exit 1
    fi

    export LITELLM_MASTER_KEY
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
    export ANTHROPIC_BASE_URL="http://localhost:${LITELLM_PORT}"
    unset ANTHROPIC_API_KEY 2>/dev/null || true

    # Start LiteLLM proxy if not already running
    if curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
        echo "LiteLLM proxy already running on port ${LITELLM_PORT}."
    else
        echo "Starting LiteLLM proxy on port ${LITELLM_PORT}..."
        litellm --config "${CLAWKEY_DIR}/litellm_config.yaml" --host 127.0.0.1 --port "$LITELLM_PORT" \
            > /tmp/litellm-clawkey.log 2>&1 &
        LITELLM_PID=$!

        echo -n "Waiting for proxy"
        for i in $(seq 1 30); do
            if curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
                echo " ready."
                break
            fi
            if ! kill -0 "$LITELLM_PID" 2>/dev/null; then
                echo ""
                echo "Error: LiteLLM proxy exited unexpectedly. Check /tmp/litellm-clawkey.log"
                tail -20 /tmp/litellm-clawkey.log 2>/dev/null
                exit 1
            fi
            echo -n "."
            sleep 1
        done

        if ! curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
            echo ""
            echo "Error: LiteLLM proxy failed to start within 30 seconds."
            echo "Log: /tmp/litellm-clawkey.log"
            tail -20 /tmp/litellm-clawkey.log 2>/dev/null
            exit 1
        fi
    fi

elif [ "$BACKEND" = "aider" ]; then
    # Aider talks directly to Portkey — no proxy needed
    export OPENAI_API_KEY="$AI_SANDBOX_KEY"
    export OPENAI_BASE_URL="https://api.portkey.ai/v1"

    if ! command -v aider &>/dev/null; then
        echo "Error: aider not found. Install it with: pip install aider-chat"
        exit 1
    fi
else
    echo "Error: Unknown backend '${BACKEND}'. Use 'claude' or 'aider'."
    exit 1
fi

echo ""
echo "Starting Ralph with ${BACKEND} backend..."
echo "  Backend:   ${BACKEND}"
echo "  Model:     ${MODEL}"
echo "  Config:    ${RALPH_CONFIG}"
if [ "$BACKEND" = "claude" ]; then
    echo "  Proxy:     http://localhost:${LITELLM_PORT}"
fi
echo "  Gateway:   https://api.portkey.ai"
echo "  Directory: ${CALLER_DIR}"
echo ""

cd "$CALLER_DIR"
ralph run -c "$RALPH_CONFIG" -a
