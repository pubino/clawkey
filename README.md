# Clawkey

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in **full interactive agent mode** with any model in the [Portkey AI Gateway](https://portkey.ai), using [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy) for protocol translation.

Optionally run the [Ralph](https://github.com/ralph-cli/ralph) orchestrator with a swappable backend: **Claude Code** or **aider**.

Everything is a `clawkey` subcommand — one CLI, one mental model.

## How It Works

```
Claude Code CLI
    |
LiteLLM Proxy (127.0.0.1:4040)
    |  translates Anthropic tool_use <> OpenAI function_call
    |
Portkey AI Gateway (api.portkey.ai)
    |  routes by model name
    |
LLM Provider
```

Claude Code sends Anthropic Messages API requests with `tool_use` blocks. LiteLLM translates these to OpenAI `/v1/chat/completions` with `function_call`, forwards to Portkey, and translates responses back.

This gives Claude Code's full interactive agent — file editing, code execution, tool use — with non-Claude models.

**Your existing Claude Code configuration is never modified.** All routing uses process-scoped environment variables (`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`) that only affect the spawned session. Your `~/.claude/`, project `.claude/`, and `ANTHROPIC_API_KEY` are untouched.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- Python 3.10+ with `litellm[proxy]`
- `AI_SANDBOX_KEY` from your institution's AI Sandbox

Optional for Ralph orchestration:
- [Ralph](https://github.com/ralph-cli/ralph) orchestrator
- [aider](https://aider.chat) (for aider backend only)

## Install

One-liner — no `sudo`, no admin privileges:

```bash
curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash
```

This installs the script tree to `$XDG_DATA_HOME/clawkey` *(default `~/.local/share/clawkey`)*, creates a Python venv with `litellm[proxy]`, and symlinks `clawkey` into `$HOME/.local/bin`. Re-running the same command updates in place.

```bash
# Update (same one-liner; idempotent)
curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash

# Reinstall (wipe install dir, fresh download + venv)
curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash -s reinstall

# Uninstall (preserves user config under ~/.config/clawkey)
curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash -s uninstall

# Uninstall AND remove user config + state
curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash -s uninstall --purge
```

You'll also need:
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- A Portkey API key (`AI_SANDBOX_KEY` from your institution's AI Sandbox)

Pin to a specific tag/branch with `CLAWKEY_REF`:

```bash
CLAWKEY_REF=v0.1.0 bash <(curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh)
```

## Quick Start

```bash
clawkey config              # set Portkey API key + default model
clawkey models --add        # add your institution's model names
clawkey proxy install       # macOS: persistent proxy (optional, no sudo)
clawkey run                 # launch Claude Code
```

The proxy starts automatically and stops when you exit. After `clawkey proxy install`, it stays up in the background and `clawkey run` is near-instant. See [Persistent proxy](#persistent-proxy-recommended).

## Persistent proxy (recommended)

By default, every `clawkey run` cold-starts a fresh LiteLLM proxy and waits up to 30 seconds for it to come up. For daily use this gets old fast. On macOS, install a user-scope launchd agent (no `sudo` required) and the proxy stays running in the background:

```bash
./clawkey proxy install        # writes ~/Library/LaunchAgents/com.clawkey.proxy.plist
./clawkey proxy status         # is it loaded? healthy?
./clawkey proxy logs           # tail ~/.clawkey/proxy.log
./clawkey proxy uninstall      # remove the agent
```

After install, `clawkey run` and `clawkey ralph` reuse the persistent proxy and start in well under a second.

Config and model edits are picked up automatically — `clawkey config`, `clawkey models --add`, and `clawkey models --remove` all kick the daemon when one is loaded.

## Configuration

```bash
./clawkey                       # Interactive menu
./clawkey status                # Show current config
./clawkey config                # Set API key and default model
./clawkey config --clear        # Clear API key and reset defaults
./clawkey models                # List configured models
./clawkey models --add          # Add a model
./clawkey models --remove       # Remove a model
```

Configuration is stored in XDG-compliant user directories — never in the project tree, so the script tree can be read-only (e.g. installed via Homebrew):

| Path | Contents |
|------|----------|
| `$XDG_CONFIG_HOME/clawkey/.env` *(default `~/.config/clawkey/.env`)* | API key, default model, proxy auth key |
| `$XDG_CONFIG_HOME/clawkey/litellm_config.yaml` | Active model list for the LiteLLM proxy (seeded from the in-tree template on first run) |
| `$XDG_STATE_HOME/clawkey/proxy.log` *(default `~/.local/state/clawkey/proxy.log`)* | Persistent-proxy log |

The `litellm_config.yaml` checked into the repo is a template (`model_list: []`); your edits via `clawkey models --add` go to the user copy under `$XDG_CONFIG_HOME/clawkey/`.

Override any path with the corresponding env var (`CLAWKEY_CONFIG_DIR`, `CLAWKEY_STATE_DIR`, `CLAWKEY_ENV_FILE`, `CLAWKEY_MODEL_CONFIG`) — useful for per-project state if you want it.

> **Migrating from a pre-XDG checkout?** First invocation of `clawkey` automatically moves your old `.env` and proxy log to the XDG locations.

## Use Cases

### Interactive Claude Code (default)

```bash
# Default model (whatever you configured via clawkey config)
./clawkey run

# Specify a working directory
./clawkey run -C ~/my-project

# Override the model for this session
PORTKEY_MODEL=<model-name> ./clawkey run

# Combine
PORTKEY_MODEL=<model-name> ./clawkey run -C ~/my-project
```

### One-shot queries

```bash
./clawkey run --print "Explain what this project does"
./clawkey run --print "Review this code for bugs" < src/main.py
```

### Ralph orchestrator with Claude Code backend

Ralph reads a task from `PROMPT.md`, runs your backend up to 100 iterations (600s timeout), and exits when the output contains `LOOP_COMPLETE`.

```bash
# 1. Write your task in PROMPT.md (must include LOOP_COMPLETE signal)
cat PROMPT.md
```

```markdown
# Task: Refactor the authentication module

## Requirements
1. Extract JWT validation into a separate middleware
2. Add refresh token rotation
3. Write tests for all new code

## Completion
When all requirements are met, output: LOOP_COMPLETE
```

```bash
# 2. Run Ralph with Claude Code backend (default)
./clawkey ralph

# Specify a working directory
./clawkey ralph -C ~/my-project

# Override the model
PORTKEY_MODEL=<model-name> ./clawkey ralph
```

Ralph calls `portkey-backend.sh` which runs `claude --print` through LiteLLM + Portkey.

### Ralph orchestrator with aider backend

Same setup, but aider talks directly to Portkey (no LiteLLM proxy needed):

```bash
CLAWKEY_BACKEND=aider ./clawkey ralph
CLAWKEY_BACKEND=aider PORTKEY_MODEL=<model-name> ./clawkey ralph
```

### Bootstrap a new project

Initialize a project directory with all Clawkey scripts and config:

```bash
cd ~/my-new-project
~/path/to/clawkey/clawkey-init.sh
```

This creates a self-contained copy of `clawkey`, `lib/`, `litellm_config.yaml`, `ralph.yml`, `portkey-backend.sh`, `PROMPT.md`, and a `.gitignore`. Then run `./clawkey config` and `./clawkey run` from inside the project.

## Models

Models are managed via the CLI. The model name must match what your institution's AI Sandbox exposes through Portkey.

```bash
./clawkey models --add      # Add a model
./clawkey models --remove   # Remove a model
./clawkey models            # List configured models
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AI_SANDBOX_KEY` | Portkey API key | *(required)* |
| `PORTKEY_MODEL` | Model name | *(required)* |
| `LITELLM_MASTER_KEY` | LiteLLM proxy auth key | auto-generated |
| `LITELLM_PORT` | LiteLLM proxy port | `4040` |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Max output tokens | `16384` |
| `CLAWKEY_BACKEND` | Ralph backend: `claude` or `aider` | `claude` |

Manage `AI_SANDBOX_KEY` and `PORTKEY_MODEL` with `./clawkey config`. All other variables are optional overrides.

## Existing Claude Code Configurations

Clawkey is designed to coexist with your normal Claude Code setup:

- **No files modified.** `clawkey run` and `clawkey ralph` set `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` as environment variables scoped to the spawned process. Your `~/.claude/`, project `.claude/settings.json`, and `ANTHROPIC_API_KEY` are never read or written.
- **No global state.** Without the persistent proxy, the LiteLLM proxy runs only while the script is active. With the persistent proxy, it runs as a user-scope launchd agent (no admin privileges) on `127.0.0.1:4040` and can be removed any time with `clawkey proxy uninstall`.
- **No credential conflicts.** `ANTHROPIC_API_KEY` is explicitly unset within the subprocess so it cannot interfere with the proxy's bearer token auth.

You can use Clawkey alongside a direct Anthropic API key for regular Claude Code. Launching `claude` normally (without `clawkey run`) uses your standard configuration as always.

## Testing

```bash
./test.sh                # Local: creates venv, installs deps, runs all tests
./test.sh --config       # Config validation only (no API key needed)
./test.sh --docker       # Run tests in Docker container
```

### Docker

```bash
docker-compose run --rm test          # Full integration tests (starts LiteLLM service)
docker-compose run --rm test-config   # Config-only tests
```

### Test Structure

| Suite | What it tests | Requires |
|-------|---------------|----------|
| `test_claude_config.py` | clawkey CLI structure, runtime lib, env wiring | Nothing |
| `test_ralph_config.py` | ralph.yml, portkey-backend.sh, PROMPT.md, ralph subcommand | Nothing |
| `test_proxy_subcommand.py` | launchd plist template, proxy install paths, no-sudo invariant | Nothing |
| `test_xdg_migration.py` | Legacy → XDG migration helpers (hermetic `$HOME`) | Nothing |
| `test_install_sh.py` | install.sh: install / update / reinstall / uninstall / purge | Nothing |
| `test_litellm_proxy.py` | Health check, Messages API, tool_use round-trip | Running proxy + API key |
| `test_portkey_connection.py` | Direct Portkey chat completions, per-model tests | API key |
