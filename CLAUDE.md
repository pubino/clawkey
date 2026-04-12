# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Clawkey routes [Claude Code](https://docs.anthropic.com/en/docs/claude-code) through [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy) and [Portkey AI Gateway](https://portkey.ai). This enables Claude Code's full interactive agent mode (tool use, file editing, code execution) with any model available in the AI Sandbox.

LiteLLM translates Anthropic tool_use <> OpenAI function_call, which Portkey alone cannot do.

Clawkey never modifies the user's existing Claude Code configuration (`~/.claude/` or project `.claude/`). All routing is done via process-scoped environment variables that only affect the spawned session.

## Architecture

```
Claude Code CLI -> LiteLLM Proxy (localhost:4040) -> Portkey AI Gateway -> LLM providers
                   (Anthropic <> OpenAI translation)   (routing by model name)
```

- **litellm_config.yaml**: LiteLLM proxy config — model list (managed via `./clawkey models --add`)
- **run.sh**: Starts LiteLLM proxy, exports env vars (`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`), launches `claude`, traps EXIT to stop proxy
- **clawkey**: Interactive CLI for managing API keys, default model, and model list
- **clawkey-init.sh**: Bootstraps new projects with all config and scripts

## Ralph Orchestration

Clawkey also supports Ralph orchestrator with a swappable backend (`claude` or `aider`):

- **ralph.yml**: Ralph config — custom backend via `portkey-backend.sh`, `LOOP_COMPLETE` signal
- **portkey-backend.sh**: Dispatches to claude or aider based on `CLAWKEY_BACKEND` env var
- **ralph-run.sh**: Starts proxy (claude mode), sets env vars, runs `ralph run`

## Commands

### Configuration

```bash
./clawkey                  # Interactive management menu
./clawkey status           # Show current configuration
./clawkey config           # Configure API key and default model
./clawkey config --clear   # Clear API key
./clawkey models           # List models
./clawkey models --add     # Add a model
./clawkey models --remove  # Remove a model
```

### Running Claude Code

```bash
./run.sh                                          # Interactive, default model
PORTKEY_MODEL=<model-name> ./run.sh                # Override model
./run.sh --print "explain this code"              # One-shot
```

### Running Ralph

```bash
./ralph-run.sh                                    # Claude Code backend (default)
CLAWKEY_BACKEND=aider ./ralph-run.sh              # aider backend
PORTKEY_MODEL=<model-name> ./ralph-run.sh          # Override model
```

### Testing

```bash
./test.sh                # Local: creates venv, installs deps, runs pytest
./test.sh --config       # Config validation only (no API key needed)
./test.sh --docker       # Run tests in Docker container
```

### Docker

```bash
docker-compose run --rm test          # Full integration tests (starts LiteLLM service)
docker-compose run --rm test-config   # Config-only tests
docker build -t clawkey:latest .      # Build test image
```

## Test Structure

- **tests/test_claude_config.py**: Config validation (run.sh structure, litellm_config.yaml) — no API key required
- **tests/test_ralph_config.py**: Ralph config validation (ralph.yml, backend script, PROMPT.md) — no API key required
- **tests/test_litellm_proxy.py**: Proxy integration tests — requires running proxy + `AI_SANDBOX_KEY`
- **tests/test_portkey_connection.py**: Direct Portkey tests — requires `AI_SANDBOX_KEY`
- **tests/conftest.py**: Fixtures that read env vars; tests skip gracefully when credentials are absent

## Environment Variables

Defined in `.env` (git-ignored). Template in `.env.example`. Manage with `./clawkey config`.

- `AI_SANDBOX_KEY`: Portkey API key
- `PORTKEY_MODEL`: Model selector (managed via `./clawkey config`)
- `LITELLM_MASTER_KEY`: LiteLLM proxy auth key (auto-generated if not set)
- `CLAWKEY_BACKEND`: Ralph backend — `claude` (default) or `aider`

## Dependencies

Python 3.10+, pytest, requests, pyyaml, litellm[proxy] (see requirements.txt). External tools: Claude Code CLI, curl, git. Optional: Ralph orchestrator, aider.
