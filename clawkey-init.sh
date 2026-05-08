#!/usr/bin/env bash
# Initialize a new Claude Code + LiteLLM + Portkey project in the current directory.
#
# Usage:
#   cd ~/my-new-project
#   ~/Downloads/clawkey/clawkey-init.sh
#
# This configures Claude Code to route through LiteLLM Proxy → Portkey AI Gateway,
# enabling interactive agent mode with non-Claude models.

set -euo pipefail

CLAWKEY_DIR="$(cd "$(dirname "$0")" && pwd)"

# Init git if needed
if [ ! -d .git ]; then
    git init
fi

# Create .env template. LITELLM_MASTER_KEY is intentionally omitted — running
# `./clawkey config` will mint a random one on first use.
if [ ! -f .env ]; then
    cat > .env << 'EOF'
AI_SANDBOX_KEY=<your-portkey-api-key>
EOF
    echo "Created .env"
else
    echo ".env already exists, skipping."
fi

# Copy clawkey itself so `./clawkey run` works in the new project.
cp "${CLAWKEY_DIR}/clawkey" .
chmod +x clawkey

# Shared runtime library + launchd template (used by `clawkey run`,
# `clawkey ralph`, `clawkey proxy *`).
cp -R "${CLAWKEY_DIR}/lib" .
chmod +x lib/launchd/run-proxy.sh

# Optional helper still useful for debugging shells.
cp "${CLAWKEY_DIR}/load-env.sh" .
chmod +x load-env.sh

# Configs.
cp "${CLAWKEY_DIR}/litellm_config.yaml" .
cp "${CLAWKEY_DIR}/ralph.yml" .

# Ralph backend wrapper (called by ralph from ralph.yml).
cp "${CLAWKEY_DIR}/portkey-backend.sh" .
chmod +x portkey-backend.sh

# Create a starter PROMPT.md if one doesn't exist
if [ ! -f PROMPT.md ]; then
    cat > PROMPT.md << 'EOF'
# Task

Describe your task here.

## Requirements

1. ...

## Acceptance Criteria

- ...

## Completion

When all requirements are met, output: LOOP_COMPLETE
EOF
    echo "Created PROMPT.md — edit it with your task."
else
    echo "PROMPT.md already exists."
fi

# Append to .gitignore
if [ ! -f .gitignore ]; then
    cat > .gitignore << 'GITEOF'
.claude/
.env
__pycache__/
*.pyc
.pytest_cache/
.venv/
.DS_Store
GITEOF
else
    for pattern in ".claude/" ".env"; do
        grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
    done
fi

echo ""
echo "Clawkey project initialized (LiteLLM + Portkey)."
echo ""
echo "  1. ./clawkey models --add        # Add your institution's models"
echo "  2. ./clawkey config              # Set API key and default model"
echo "  3. pip install 'litellm[proxy]'  # (or use Docker)"
echo "  4. ./clawkey proxy install       # macOS: persistent proxy, no sudo (optional)"
echo "  5. ./clawkey run                 # Interactive Claude Code"
echo ""
echo "Tip: alias ck=\"\$PWD/clawkey\" — then use 'ck run', 'ck ralph', etc."
