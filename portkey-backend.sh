#!/usr/bin/env bash
# Unified Ralph backend wrapper — dispatches to claude or aider.
# Ralph's custom backend calls this with the prompt as an argument.
#
# Reads CLAWKEY_BACKEND env var:
#   claude (default) — claude --print via LiteLLM proxy (must be running)
#   aider            — aider --message direct to Portkey
#
# Required env vars:
#   CLAWKEY_BACKEND   - "claude" or "aider" (default: claude)
#   PORTKEY_MODEL     - model name (default: gpt-4o-mini)
#
# Claude mode also requires:
#   ANTHROPIC_AUTH_TOKEN  - LiteLLM master key
#   ANTHROPIC_BASE_URL    - http://localhost:4040
#
# Aider mode also requires:
#   OPENAI_API_KEY   - Portkey API key
#   OPENAI_BASE_URL  - https://api.portkey.ai/v1

set -euo pipefail

BACKEND="${CLAWKEY_BACKEND:-claude}"
MODEL="${PORTKEY_MODEL:-gemini-3.1-pro-preview}"
PROMPT="$*"

if [ -z "$PROMPT" ]; then
    echo "Error: No prompt provided."
    exit 1
fi

case "$BACKEND" in
    claude)
        # Verify LiteLLM proxy is reachable
        LITELLM_PORT="${LITELLM_PORT:-4040}"
        if ! curl -sf "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
            echo "Error: LiteLLM proxy not reachable on port ${LITELLM_PORT}."
            echo "Start it with ralph-run.sh or run.sh first."
            exit 1
        fi

        exec claude --print --model "$MODEL" "$PROMPT"
        ;;
    aider)
        if [ -z "${OPENAI_API_KEY:-}" ]; then
            echo "Error: OPENAI_API_KEY not set for aider backend."
            exit 1
        fi

        exec aider \
            --model "openai/${MODEL}" \
            --message "${PROMPT}" \
            --yes-always \
            --no-auto-commits \
            --no-suggest-shell-commands \
            --no-show-model-warnings
        ;;
    *)
        echo "Error: Unknown backend '${BACKEND}'. Use 'claude' or 'aider'."
        exit 1
        ;;
esac
