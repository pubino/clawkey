#!/usr/bin/env bash
# install.sh — install, update, reinstall, or uninstall Clawkey.
#
#   curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash -s reinstall
#   curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash -s uninstall
#   curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash -s uninstall --purge
#
# No admin privileges required. Writes only to user-scope paths.
#
# Layout:
#   $XDG_DATA_HOME/clawkey/         install dir (script tree + .venv)   default ~/.local/share/clawkey
#   $HOME/.local/bin/clawkey        symlink into PATH
#   $XDG_CONFIG_HOME/clawkey/       user config (.env, litellm_config.yaml)
#   $XDG_STATE_HOME/clawkey/        user state (proxy.log)
#
# Honored env vars (all optional):
#   CLAWKEY_REPO=<owner/name>       default: pubino/clawkey
#   CLAWKEY_REF=<branch|tag|sha>    default: latest release, falling back to main
#   CLAWKEY_INSTALL_DIR=<path>      default: $XDG_DATA_HOME/clawkey
#   CLAWKEY_BIN_DIR=<path>          default: $HOME/.local/bin
#   CLAWKEY_TARBALL=<path|url>      override the tarball source (test hook)
#   CLAWKEY_SKIP_VENV=1             skip pip install (test hook)
#
# Uninstall preserves user XDG state by default; pass --purge to remove it.

set -euo pipefail

CLAWKEY_REPO="${CLAWKEY_REPO:-pubino/clawkey}"
CLAWKEY_REF="${CLAWKEY_REF:-}"
CLAWKEY_INSTALL_DIR="${CLAWKEY_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/clawkey}"
CLAWKEY_BIN_DIR="${CLAWKEY_BIN_DIR:-$HOME/.local/bin}"
CLAWKEY_CONFIG_DIR="${CLAWKEY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/clawkey}"
CLAWKEY_STATE_DIR="${CLAWKEY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/clawkey}"

# ── Pretty output ──────────────────────────────────────────────────

if [ -t 1 ]; then
    _green=$'\033[0;32m'; _yellow=$'\033[1;33m'; _red=$'\033[0;31m'; _dim=$'\033[2m'; _reset=$'\033[0m'
else
    _green=""; _yellow=""; _red=""; _dim=""; _reset=""
fi

info() { echo "${_dim}→${_reset} $*"; }
ok()   { echo "${_green}✓${_reset} $*"; }
warn() { echo "${_yellow}!${_reset} $*"; }
err()  { echo "${_red}✗${_reset} $*" >&2; }

# ── Preflight ──────────────────────────────────────────────────────

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "required command not found: $1"
        return 127
    fi
}

require_python() {
    require_cmd python3 || exit $?
    local v
    v=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    case "$v" in
        3.10|3.11|3.12|3.13|3.14|3.1[5-9]|3.[2-9]?|[4-9].*)
            ;;
        *)
            err "Python 3.10+ required (found $v). See https://www.python.org/downloads/"
            exit 1
            ;;
    esac
}

resolve_ref() {
    if [ -n "$CLAWKEY_REF" ]; then
        echo "$CLAWKEY_REF"
        return
    fi
    # Try the GitHub Releases API. Falls back to main if no release exists.
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/${CLAWKEY_REPO}/releases/latest" 2>/dev/null \
          | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    if [ -z "$tag" ]; then
        echo "main"
    else
        echo "$tag"
    fi
}

# ── install / update ───────────────────────────────────────────────

cmd_install() {
    require_cmd curl    || exit $?
    require_cmd tar     || exit $?
    require_python

    local tmp source desc
    tmp=$(mktemp -d -t clawkey-install.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    if [ -n "${CLAWKEY_TARBALL:-}" ]; then
        source="$CLAWKEY_TARBALL"
        desc="$CLAWKEY_TARBALL"
        info "Using tarball override: $desc"
    else
        local ref
        ref=$(resolve_ref)
        source="https://github.com/${CLAWKEY_REPO}/archive/${ref}.tar.gz"
        desc="${CLAWKEY_REPO}@${ref}"
        info "Installing Clawkey from $desc"
    fi

    info "Fetching tarball..."
    if [[ "$source" == file://* || "$source" == /* ]]; then
        # Local file (test hook).
        local local_path="${source#file://}"
        tar -xzf "$local_path" -C "$tmp" --strip-components=1
    else
        curl -fsSL "$source" | tar -xz -C "$tmp" --strip-components=1
    fi

    if [ ! -f "$tmp/clawkey" ] || [ ! -d "$tmp/lib" ]; then
        err "Tarball missing expected files. Got:"
        ls "$tmp" >&2
        exit 1
    fi

    mkdir -p "$CLAWKEY_INSTALL_DIR"

    info "Syncing into ${CLAWKEY_INSTALL_DIR}"
    # rsync ships with macOS and is in the default Linux distros we care about.
    # --delete drops files that have been removed upstream; --exclude .venv
    # preserves the (rebuilt) virtualenv across updates.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude '.venv' "$tmp/" "$CLAWKEY_INSTALL_DIR/"
    else
        # Fallback: blow away non-venv contents, then copy.
        find "$CLAWKEY_INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name '.venv' -exec rm -rf {} +
        cp -R "$tmp/." "$CLAWKEY_INSTALL_DIR/"
    fi

    chmod +x "$CLAWKEY_INSTALL_DIR/clawkey"
    [ -f "$CLAWKEY_INSTALL_DIR/lib/launchd/run-proxy.sh" ] && chmod +x "$CLAWKEY_INSTALL_DIR/lib/launchd/run-proxy.sh"

    if [ -z "${CLAWKEY_SKIP_VENV:-}" ]; then
        info "Setting up Python venv with litellm[proxy] (one minute on first install)..."
        if [ ! -d "$CLAWKEY_INSTALL_DIR/.venv" ]; then
            python3 -m venv "$CLAWKEY_INSTALL_DIR/.venv"
        fi
        "$CLAWKEY_INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
        "$CLAWKEY_INSTALL_DIR/.venv/bin/pip" install --quiet -r "$CLAWKEY_INSTALL_DIR/requirements.txt"
    else
        warn "CLAWKEY_SKIP_VENV set — venv not configured. clawkey run will require litellm on PATH."
    fi

    mkdir -p "$CLAWKEY_BIN_DIR"
    ln -sf "$CLAWKEY_INSTALL_DIR/clawkey" "$CLAWKEY_BIN_DIR/clawkey"

    ok "Installed at ${CLAWKEY_INSTALL_DIR}"
    ok "Symlinked ${CLAWKEY_BIN_DIR}/clawkey"

    # Helpful nudges, but don't fail if these tools are missing.
    if ! echo ":$PATH:" | grep -qF ":${CLAWKEY_BIN_DIR}:"; then
        echo
        warn "${CLAWKEY_BIN_DIR} is not on your PATH. Add to your shell rc:"
        echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    fi
    if ! command -v claude >/dev/null 2>&1; then
        echo
        warn "Claude Code CLI not found. Install it with:"
        echo "    npm install -g @anthropic-ai/claude-code"
    fi

    cat <<MSG

${_dim}Next steps:${_reset}
  clawkey config              # set Portkey API key + default model
  clawkey models --add        # add your institution's models
  clawkey proxy install       # macOS: persistent proxy (optional, no sudo)
  clawkey run                 # launch Claude Code
MSG
}

# ── reinstall ──────────────────────────────────────────────────────

cmd_reinstall() {
    if [ -d "$CLAWKEY_INSTALL_DIR" ]; then
        info "Wiping ${CLAWKEY_INSTALL_DIR} for clean reinstall"
        rm -rf "$CLAWKEY_INSTALL_DIR"
    fi
    cmd_install
}

# ── uninstall ──────────────────────────────────────────────────────

cmd_uninstall() {
    local purge=0
    shift || true
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --purge) purge=1 ;;
            *) err "uninstall: unknown flag $1"; exit 1 ;;
        esac
        shift
    done

    # Best-effort: stop and unload the launchd agent before removing the install.
    if [ -x "$CLAWKEY_INSTALL_DIR/clawkey" ]; then
        "$CLAWKEY_INSTALL_DIR/clawkey" proxy uninstall >/dev/null 2>&1 || true
    fi

    if [ -L "$CLAWKEY_BIN_DIR/clawkey" ]; then
        rm -f "$CLAWKEY_BIN_DIR/clawkey"
        ok "Removed ${CLAWKEY_BIN_DIR}/clawkey"
    fi

    if [ -d "$CLAWKEY_INSTALL_DIR" ]; then
        rm -rf "$CLAWKEY_INSTALL_DIR"
        ok "Removed ${CLAWKEY_INSTALL_DIR}"
    else
        info "Install dir already absent: ${CLAWKEY_INSTALL_DIR}"
    fi

    if [ "$purge" = "1" ]; then
        for d in "$CLAWKEY_CONFIG_DIR" "$CLAWKEY_STATE_DIR"; do
            if [ -d "$d" ]; then
                rm -rf "$d"
                ok "Removed ${d}"
            fi
        done
    else
        if [ -d "$CLAWKEY_CONFIG_DIR" ] || [ -d "$CLAWKEY_STATE_DIR" ]; then
            info "User config preserved (${CLAWKEY_CONFIG_DIR}). Pass --purge to remove."
        fi
    fi

    ok "Uninstalled."
}

# ── dispatch ───────────────────────────────────────────────────────

case "${1:-install}" in
    install|update)  cmd_install ;;
    reinstall)       cmd_reinstall ;;
    uninstall)       cmd_uninstall "$@" ;;
    -h|--help|help)
        cat <<HELP
clawkey install.sh — install, update, reinstall, or uninstall Clawkey.

Usage:
  curl -fsSL https://raw.githubusercontent.com/${CLAWKEY_REPO}/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/${CLAWKEY_REPO}/main/install.sh | bash -s reinstall
  curl -fsSL https://raw.githubusercontent.com/${CLAWKEY_REPO}/main/install.sh | bash -s uninstall [--purge]

Environment overrides:
  CLAWKEY_REPO          owner/name (default: pubino/clawkey)
  CLAWKEY_REF           branch/tag/sha (default: latest release, falls back to main)
  CLAWKEY_INSTALL_DIR   install location (default: \$XDG_DATA_HOME/clawkey)
  CLAWKEY_BIN_DIR       symlink target (default: \$HOME/.local/bin)

Test hooks:
  CLAWKEY_TARBALL       local path or file:// URL to a clawkey tarball
  CLAWKEY_SKIP_VENV=1   skip pip install (CI / sandboxed tests)
HELP
        ;;
    *)
        err "Unknown command: $1"
        echo "  Try: bash install.sh help"
        exit 1
        ;;
esac
