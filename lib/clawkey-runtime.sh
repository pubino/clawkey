#!/usr/bin/env bash
# clawkey-runtime — shared shell library for the clawkey CLI runtime.
#
# Sourced by `clawkey run`, `clawkey ralph`, and `clawkey proxy *`.
# Defines functions only; safe to source repeatedly.
#
# Functions defined here are prefixed `clawkey_` to avoid namespace collisions.
# Constants are UPPER_SNAKE_CASE.
#
# Required by callers:
#   CLAWKEY_DIR  — absolute path to the clawkey checkout (where litellm_config.yaml lives)
#
# Provides (after sourcing):
#   CLAWKEY_STATE_DIR, CLAWKEY_PROXY_LOG, CLAWKEY_LAUNCHD_LABEL, CLAWKEY_LAUNCHD_PLIST
#   clawkey_state_dir_init
#   clawkey_load_env
#   clawkey_require_litellm
#   clawkey_require_env
#   clawkey_proxy_running
#   clawkey_proxy_start_ephemeral
#   clawkey_proxy_wait_ready
#   clawkey_proxy_stop_ephemeral
#   clawkey_proxy_loaded
#   clawkey_proxy_reload_if_loaded
#   clawkey_export_anthropic_env
#   clawkey_parse_caller_dir

# ── Paths and labels ────────────────────────────────────────────────

CLAWKEY_STATE_DIR="${CLAWKEY_STATE_DIR:-$HOME/.clawkey}"
CLAWKEY_PROXY_LOG="${CLAWKEY_PROXY_LOG:-$CLAWKEY_STATE_DIR/proxy.log}"
CLAWKEY_LAUNCHD_LABEL="com.clawkey.proxy"
CLAWKEY_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${CLAWKEY_LAUNCHD_LABEL}.plist"

# Module-private state for the ephemeral proxy path.
_CLAWKEY_LITELLM_PID=""

clawkey_state_dir_init() {
    mkdir -p "$CLAWKEY_STATE_DIR"
}

# ── Env loading ─────────────────────────────────────────────────────

# Source .env from CLAWKEY_DIR. Existing env vars take precedence over file values.
clawkey_load_env() {
    local env_file="${CLAWKEY_DIR}/.env"
    if [ ! -f "$env_file" ]; then
        echo "Error: ${env_file} not found. Run: clawkey config" >&2
        return 1
    fi
    local _line _key _val
    while IFS= read -r _line || [ -n "$_line" ]; do
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        _key="${_line%%=*}"
        _val="${_line#*=}"
        if [ -z "${!_key+x}" ]; then
            export "$_key=$_val"
        fi
    done < "$env_file"
}

# Verify required env vars are non-empty. Args: list of var names.
clawkey_require_env() {
    local var
    local missing=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            echo "Error: $var is not set. Run: clawkey config" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

# Activate venv if present, then verify litellm is on PATH.
clawkey_require_litellm() {
    if [ -d "${CLAWKEY_DIR}/.venv" ]; then
        # shellcheck disable=SC1091
        source "${CLAWKEY_DIR}/.venv/bin/activate"
    fi
    if ! command -v litellm &>/dev/null; then
        echo "Error: litellm not found. Install it with: pip install 'litellm[proxy]'" >&2
        return 1
    fi
}

# ── Proxy health ────────────────────────────────────────────────────

# Return 0 if /health on the configured port responds 200, else 1.
# Uses LITELLM_MASTER_KEY if set (for protected /health), else unauthenticated.
clawkey_proxy_running() {
    local port="${LITELLM_PORT:-4040}"
    local url="http://127.0.0.1:${port}/health"
    if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
        curl -sf -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "$url" >/dev/null 2>&1
    else
        curl -sf "$url" >/dev/null 2>&1
    fi
}

# Start the proxy as a child of this shell. Caller must have set
# LITELLM_MASTER_KEY and run clawkey_require_litellm first. Records the PID
# in _CLAWKEY_LITELLM_PID so clawkey_proxy_stop_ephemeral can clean up via trap.
clawkey_proxy_start_ephemeral() {
    local port="${LITELLM_PORT:-4040}"
    clawkey_state_dir_init
    echo "Starting LiteLLM proxy on port ${port}..."
    litellm --config "${CLAWKEY_DIR}/litellm_config.yaml" \
            --host 127.0.0.1 --port "$port" \
        > "$CLAWKEY_PROXY_LOG" 2>&1 &
    _CLAWKEY_LITELLM_PID=$!
}

# Poll /health for up to 30s. Returns 0 if healthy, 1 if timed out or proxy died.
# Tails the log on failure so the user sees the litellm error.
clawkey_proxy_wait_ready() {
    local i
    echo -n "Waiting for proxy"
    for i in $(seq 1 30); do
        if clawkey_proxy_running; then
            echo " ready."
            return 0
        fi
        if [ -n "$_CLAWKEY_LITELLM_PID" ] && ! kill -0 "$_CLAWKEY_LITELLM_PID" 2>/dev/null; then
            echo ""
            echo "Error: LiteLLM proxy exited unexpectedly. Log: ${CLAWKEY_PROXY_LOG}" >&2
            tail -20 "$CLAWKEY_PROXY_LOG" 2>/dev/null >&2
            return 1
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    echo "Error: LiteLLM proxy failed to start within 30 seconds. Log: ${CLAWKEY_PROXY_LOG}" >&2
    tail -20 "$CLAWKEY_PROXY_LOG" 2>/dev/null >&2
    return 1
}

# Trap helper for the ephemeral path. Safe to call when no child was started.
clawkey_proxy_stop_ephemeral() {
    if [ -n "$_CLAWKEY_LITELLM_PID" ] && kill -0 "$_CLAWKEY_LITELLM_PID" 2>/dev/null; then
        echo ""
        echo "Stopping LiteLLM proxy (PID $_CLAWKEY_LITELLM_PID)..."
        kill "$_CLAWKEY_LITELLM_PID" 2>/dev/null || true
        wait "$_CLAWKEY_LITELLM_PID" 2>/dev/null || true
    fi
}

# ── launchd integration (macOS, user-scope only) ────────────────────

# Return 0 if a user agent for our label is loaded, 1 otherwise.
# `launchctl print gui/$UID/<label>` exits 0 if loaded, 113 if not.
clawkey_proxy_loaded() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    launchctl print "gui/$(id -u)/${CLAWKEY_LAUNCHD_LABEL}" >/dev/null 2>&1
}

# Kickstart the daemon if loaded (so config/model changes take effect).
# No-op when no daemon is loaded — keeps callers (config writers, model edits)
# free of "is the daemon running?" branching.
clawkey_proxy_reload_if_loaded() {
    if clawkey_proxy_loaded; then
        launchctl kickstart -k "gui/$(id -u)/${CLAWKEY_LAUNCHD_LABEL}" >/dev/null 2>&1 || true
    fi
}

# ── Anthropic env wiring ────────────────────────────────────────────

# Set ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL; unset ANTHROPIC_API_KEY.
# Caller must have set LITELLM_MASTER_KEY and (optionally) LITELLM_PORT.
clawkey_export_anthropic_env() {
    local port="${LITELLM_PORT:-4040}"
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${port}"
    unset ANTHROPIC_API_KEY 2>/dev/null || true
}

# ── -C <dir> arg parser ─────────────────────────────────────────────

# Echoes the resolved working directory and prints the number of args to shift
# on stderr's last line. Use as:
#   read -r CALLER_DIR _shift < <(clawkey_parse_caller_dir "$@")
# but the simpler bash pattern is to call it via a wrapper that mutates argv.
# The clawkey CLI handles -C directly in its subcommand dispatcher to avoid
# subshell awkwardness; this helper is provided for symmetry / future use.
clawkey_parse_caller_dir() {
    if [ "${1:-}" = "-C" ]; then
        if [ -z "${2:-}" ]; then
            echo "Error: -C requires a directory argument." >&2
            return 1
        fi
        (cd "$2" && pwd)
        return 0
    fi
    pwd
}
