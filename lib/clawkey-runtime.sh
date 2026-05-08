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

# ── Paths and labels (XDG Base Directory Specification) ────────────
#
# User-mutable state lives under XDG-defined dirs so the script tree
# (CLAWKEY_DIR — typically a Homebrew Cellar path or a git checkout)
# can be read-only. Override individual constants if you want a custom
# layout (e.g. CLAWKEY_CONFIG_DIR=$PWD/.clawkey for per-project state).

CLAWKEY_CONFIG_DIR="${CLAWKEY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/clawkey}"
CLAWKEY_STATE_DIR="${CLAWKEY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/clawkey}"
CLAWKEY_ENV_FILE="${CLAWKEY_ENV_FILE:-$CLAWKEY_CONFIG_DIR/.env}"
CLAWKEY_MODEL_CONFIG="${CLAWKEY_MODEL_CONFIG:-$CLAWKEY_CONFIG_DIR/litellm_config.yaml}"
CLAWKEY_PROXY_LOG="${CLAWKEY_PROXY_LOG:-$CLAWKEY_STATE_DIR/proxy.log}"
CLAWKEY_LAUNCHD_LABEL="com.clawkey.proxy"
CLAWKEY_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${CLAWKEY_LAUNCHD_LABEL}.plist"

# Module-private state for the ephemeral proxy path.
_CLAWKEY_LITELLM_PID=""

clawkey_config_dir_init() {
    mkdir -p "$CLAWKEY_CONFIG_DIR"
}

clawkey_state_dir_init() {
    mkdir -p "$CLAWKEY_STATE_DIR"
}

# Ensure CLAWKEY_ENV_FILE is owner-only (0600). The .env holds AI_SANDBOX_KEY
# and LITELLM_MASTER_KEY; default umask on most shells creates files at 0644
# which lets any local user read them. Idempotent and quiet on missing file.
clawkey_secure_env_file_perms() {
    [ -f "$CLAWKEY_ENV_FILE" ] && chmod 0600 "$CLAWKEY_ENV_FILE" 2>/dev/null || true
}

# Seed CLAWKEY_MODEL_CONFIG from the in-tree template on first use so
# `clawkey models --add` has a file to edit.
clawkey_seed_model_config() {
    if [ ! -f "$CLAWKEY_MODEL_CONFIG" ] && [ -f "$CLAWKEY_DIR/litellm_config.yaml" ]; then
        clawkey_config_dir_init
        cp "$CLAWKEY_DIR/litellm_config.yaml" "$CLAWKEY_MODEL_CONFIG"
    fi
}

# One-shot migration from the pre-XDG layout. Moves CLAWKEY_DIR-local .env
# to the XDG config dir and migrates the proxy log out of ~/.clawkey/.
# litellm_config.yaml is handled by clawkey_seed_model_config, which fires
# whether the in-tree file is a template or already has user models.
# Each branch is a no-op once the destination exists.
clawkey_migrate_legacy_config() {
    local legacy_env="$CLAWKEY_DIR/.env"
    if [ -f "$legacy_env" ] && [ ! -f "$CLAWKEY_ENV_FILE" ]; then
        clawkey_config_dir_init
        mv "$legacy_env" "$CLAWKEY_ENV_FILE"
        # mv preserves the source's mode; the legacy .env was likely 0644.
        # Tighten now so the secret isn't world-readable.
        clawkey_secure_env_file_perms
        echo "Moved $legacy_env -> $CLAWKEY_ENV_FILE (XDG layout)" >&2
    fi
    local legacy_log="$HOME/.clawkey/proxy.log"
    if [ -f "$legacy_log" ] && [ ! -f "$CLAWKEY_PROXY_LOG" ]; then
        clawkey_state_dir_init
        mv "$legacy_log" "$CLAWKEY_PROXY_LOG" 2>/dev/null || true
    fi
}

# ── Env loading ─────────────────────────────────────────────────────

# Source CLAWKEY_ENV_FILE. Existing env vars take precedence over file values.
clawkey_load_env() {
    if [ ! -f "$CLAWKEY_ENV_FILE" ]; then
        echo "Error: ${CLAWKEY_ENV_FILE} not found. Run: clawkey config" >&2
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
    done < "$CLAWKEY_ENV_FILE"
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
        clawkey_proxy_wait_running >/dev/null
    fi
}

# Poll /health until the proxy responds or 10s elapses. Best-effort: returns 0
# on success, 1 on timeout — callers decide whether to surface the timeout.
# Sources LITELLM_MASTER_KEY from .env if it isn't already in the environment
# (callers like clawkey_proxy_reload_if_loaded run from contexts that don't
# inherit it). Restores the unset state on exit.
clawkey_proxy_wait_running() {
    local _had_key="${LITELLM_MASTER_KEY:-}"
    if [ -z "$_had_key" ] && [ -f "$CLAWKEY_ENV_FILE" ]; then
        local _k
        _k=$(grep -m1 '^LITELLM_MASTER_KEY=' "$CLAWKEY_ENV_FILE" 2>/dev/null | cut -d= -f2-)
        [ -n "$_k" ] && export LITELLM_MASTER_KEY="$_k"
    fi
    local _rc=1 _i
    for _i in $(seq 1 10); do
        if clawkey_proxy_running; then
            _rc=0
            break
        fi
        sleep 1
    done
    [ -z "$_had_key" ] && unset LITELLM_MASTER_KEY 2>/dev/null || true
    return "$_rc"
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
