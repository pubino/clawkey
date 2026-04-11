# Clawkey

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in **full interactive agent mode** with any model in the [Portkey AI Gateway](https://portkey.ai) — OpenAI, Google Gemini, Meta Llama, Mistral — using [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy) for protocol translation.

Optionally run the [Ralph](https://github.com/ralph-cli/ralph) orchestrator with a swappable backend: **Claude Code** or **aider**.

## How It Works

```
Claude Code CLI
    |
LiteLLM Proxy (localhost:4040)
    |  translates Anthropic tool_use <> OpenAI function_call
    |
Portkey AI Gateway (api.portkey.ai)
    |  routes by model name
    |
LLM Provider (OpenAI, Google, Mistral, Meta/Azure)
```

Claude Code sends Anthropic Messages API requests with `tool_use` blocks. LiteLLM translates these to OpenAI `/v1/chat/completions` with `function_call`, forwards to Portkey, and translates responses back. This gives Claude Code's full interactive agent — file editing, code execution, tool use — with non-Claude models.

**Your existing Claude Code configuration is never modified.** All routing uses process-scoped environment variables (`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`) that only affect the spawned session. Your `~/.claude/`, project `.claude/`, and `ANTHROPIC_API_KEY` are untouched.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- Python 3.10+ with `litellm[proxy]` (`pip install 'litellm[proxy]'`)
- `AI_SANDBOX_KEY` from your institution's AI Sandbox

Optional for Ralph orchestration:
- [Ralph](https://github.com/ralph-cli/ralph) orchestrator
- [aider](https://aider.chat) (for aider backend only)

## Quick Start

```bash
# 1. Configure your API key and model
./clawkey config

# 2. Launch Claude Code
./run.sh
```

That's it. The proxy starts automatically, Claude Code opens in your working directory, and the proxy stops when you exit.

## Configuration

Clawkey includes an interactive CLI for managing your API key, default model, and model list.

```bash
./clawkey              # Interactive menu
./clawkey status       # Show current config at a glance
./clawkey config       # Set API key and default model
./clawkey config --clear   # Clear API key and reset defaults
./clawkey models       # List configured models
./clawkey models --add     # Add a model to the list
./clawkey models --remove  # Remove a model from the list
```

Running `./clawkey` with no arguments opens an interactive menu:

```
  ╭──────────────────────────────────────────╮
  │  Clawkey  Claude Code + Portkey Gateway  │
  ╰──────────────────────────────────────────╯

    1)  Show status
    2)  Configure API key and model
    3)  List models
    4)  Add a model
    5)  Remove a model
    6)  Clear configuration
    q)  Exit
```

Configuration is stored in two files:

| File | Contents | Git-tracked? |
|------|----------|:---:|
| `setup-env.sh` | API key, default model | No |
| `litellm_config.yaml` | Full model list for LiteLLM proxy | Yes |

## Use Cases

### Interactive Claude Code (default)

Start Claude Code in your current directory, routed through LiteLLM + Portkey:

```bash
# Default model (gemini-3.1-pro-preview or whatever you configured)
./run.sh

# Specify a working directory (-C must be the first argument)
~/Downloads/clawkey/run.sh -C ~/my-project

# Override model for this session
PORTKEY_MODEL=gpt-5-mini ./run.sh
PORTKEY_MODEL=mistral-medium-2505 ./run.sh

# Combine -C with model override
PORTKEY_MODEL=gpt-5-mini ~/Downloads/clawkey/run.sh -C ~/my-project
```

### One-shot queries

```bash
# Print mode — no interactive session
./run.sh --print "Explain what this project does"

# Pipe a file for analysis
./run.sh --print "Review this code for bugs" < src/main.py
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
~/Downloads/clawkey/ralph-run.sh

# Specify a working directory
~/Downloads/clawkey/ralph-run.sh -C ~/my-project

# Override model
PORTKEY_MODEL=gpt-5-mini ~/Downloads/clawkey/ralph-run.sh
```

Ralph calls `portkey-backend.sh` which runs `claude --print` through LiteLLM + Portkey.

### Ralph orchestrator with aider backend

Same setup, but aider talks directly to Portkey (no LiteLLM proxy needed):

```bash
CLAWKEY_BACKEND=aider ~/Downloads/clawkey/ralph-run.sh

# With a different model
CLAWKEY_BACKEND=aider PORTKEY_MODEL=mistral-small-2503 ~/Downloads/clawkey/ralph-run.sh
```

### Bootstrap a new project

Initialize a project directory with all Clawkey scripts and config:

```bash
cd ~/my-new-project
~/Downloads/clawkey/clawkey-init.sh
```

This creates:
- `setup-env.sh` — credential template
- `run.sh` — Claude Code launcher
- `ralph-run.sh` — Ralph launcher
- `portkey-backend.sh` — Ralph backend wrapper
- `ralph.yml` — Ralph orchestration config
- `litellm_config.yaml` — LiteLLM model list
- `PROMPT.md` — task template with `LOOP_COMPLETE` signal
- `.gitignore` — excludes secrets and generated files

## Available Models

| Provider | Models | Max Output Tokens |
|----------|--------|------------------:|
| OpenAI | `gpt-4o-mini`, `gpt-5-mini` | 16384 |
| Google | `gemini-3.1-pro-preview` | 65536+ |
| Mistral | `mistral-small-2503`, `mistral-medium-2505` | 32768 |
| Meta (Azure) | `Llama-3.3-70B-Instruct`, `Meta-Llama-3-1-8B-Instruct` | 4096 |

Add or remove models with `./clawkey models --add` and `./clawkey models --remove`. The model name must match what Portkey exposes for your AI Sandbox.

Llama models have low output limits and may truncate longer responses.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AI_SANDBOX_KEY` | Portkey API key | *(required)* |
| `PORTKEY_MODEL` | Model name | `gemini-3.1-pro-preview` |
| `LITELLM_MASTER_KEY` | LiteLLM proxy auth key | auto-generated |
| `LITELLM_PORT` | LiteLLM proxy port | `4040` |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Max output tokens | `16384` |
| `CLAWKEY_BACKEND` | Ralph backend: `claude` or `aider` | `claude` |

Manage `AI_SANDBOX_KEY` and `PORTKEY_MODEL` with `./clawkey config`. All other variables are optional overrides.

## Existing Claude Code Configurations

Clawkey is designed to coexist with your normal Claude Code setup:

- **No files modified.** `run.sh` and `ralph-run.sh` set `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` as environment variables scoped to the spawned process. Your `~/.claude/`, project `.claude/settings.json`, and `ANTHROPIC_API_KEY` are never read or written.
- **No global state.** The LiteLLM proxy runs on `localhost:4040` only while the script is active and stops automatically on exit.
- **No credential conflicts.** `ANTHROPIC_API_KEY` is explicitly unset within the subprocess so it cannot interfere with the proxy's bearer token auth.

You can use Clawkey alongside a direct Anthropic API key for regular Claude Code. Launching `claude` normally (without `run.sh`) uses your standard configuration as always.

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
| `test_claude_config.py` | run.sh structure, litellm_config.yaml, env vars | Nothing |
| `test_ralph_config.py` | ralph.yml, portkey-backend.sh, PROMPT.md | Nothing |
| `test_litellm_proxy.py` | Health check, Messages API, tool_use round-trip | Running proxy + API key |
| `test_portkey_connection.py` | Direct Portkey chat completions, per-model tests | API key |
