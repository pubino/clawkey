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

# Create setup-env.sh template
if [ ! -f setup-env.sh ]; then
    cat > setup-env.sh << 'EOF'
#!/usr/bin/env bash
# Source this file to load Portkey credentials.
# Uses the same AI_SANDBOX_KEY as ralphkey.

export AI_SANDBOX_KEY="${AI_SANDBOX_KEY:-<your-portkey-api-key>}"
export PORTKEY_MODEL="${PORTKEY_MODEL:-gemini-3.1-pro-preview}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-clawkey-local}"
EOF
    chmod +x setup-env.sh
    echo "Created setup-env.sh — edit it with your AI_SANDBOX_KEY."
else
    echo "setup-env.sh already exists, skipping."
fi

# Copy run.sh, litellm_config.yaml, and Ralph files
cp "${CLAWKEY_DIR}/run.sh" .
chmod +x run.sh

cp "${CLAWKEY_DIR}/litellm_config.yaml" .

cp "${CLAWKEY_DIR}/portkey-backend.sh" .
chmod +x portkey-backend.sh

cp "${CLAWKEY_DIR}/ralph-run.sh" .
chmod +x ralph-run.sh

cp "${CLAWKEY_DIR}/ralph.yml" .

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
setup-env.sh
.env
__pycache__/
*.pyc
.pytest_cache/
.venv/
.DS_Store
GITEOF
else
    for pattern in ".claude/" "setup-env.sh" ".env"; do
        grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
    done
fi

echo ""
echo "Clawkey project initialized (LiteLLM + Portkey)."
echo ""
echo "  1. Edit setup-env.sh with your AI_SANDBOX_KEY"
echo "  2. source setup-env.sh"
echo "  3. pip install litellm[proxy]  (or use Docker)"
echo "  4. ./run.sh                              # Interactive Claude Code"
echo "  5. ./ralph-run.sh                        # Ralph + Claude Code backend"
echo "  6. CLAWKEY_BACKEND=aider ./ralph-run.sh  # Ralph + aider backend"
