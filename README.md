# Clawkey

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in interactive agent mode with any model behind the [Portkey AI Gateway](https://portkey.ai), using [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy) for protocol translation. Optionally drives the [Ralph](https://github.com/ralph-cli/ralph) orchestrator with a `claude` or `aider` backend.

## How it works

```
Claude Code  →  LiteLLM Proxy (127.0.0.1:4040)  →  Portkey AI Gateway  →  LLM provider
                  Anthropic ⇄ OpenAI translation       routes by model name
```

LiteLLM translates Anthropic `tool_use` blocks ↔ OpenAI `function_call` so Claude Code's agent loop (file editing, code execution, tool use) works against non-Claude models.

clawkey sets `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` on the `claude` subprocess it spawns — nothing else. Your shell, `~/.claude/`, project `.claude/`, and `ANTHROPIC_API_KEY` are never read or modified, so `claude` invoked outside clawkey still uses your normal Anthropic setup.

## Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh | bash
```

Installs the script tree to `$XDG_DATA_HOME/clawkey`.  Re-run to update in place.

```bash
| bash -s reinstall              # wipe install dir, fresh download + venv
| bash -s uninstall              # remove install (keeps user config)
| bash -s uninstall --purge      # also remove ~/.config/clawkey + ~/.local/state/clawkey
```

You'll also need the Claude Code CLI (`npm install -g @anthropic-ai/claude-code` or `brew install claude-code`) and a Portkey API key from your institution's AI Sandbox.

## First-run setup

```bash
clawkey config              # set API key + default model
clawkey models --add        # add your institution's model names
clawkey proxy install       # macOS: persistent proxy in the background (optional)
clawkey run                 # launch Claude Code
```

Without `proxy install`, every `clawkey run` cold-starts a fresh proxy (~30s wait). With it, the proxy lives in a user-scope launchd agent (`~/Library/LaunchAgents/com.clawkey.proxy.plist`) and `clawkey run` is sub-second.

Edits via `clawkey config` or `clawkey models --add/--remove` reload the daemon automatically.

## Daily use

```bash
clawkey run                              # interactive Claude Code
clawkey run -C ~/some-project            # set working directory
clawkey run --print "explain this"       # one-shot
PORTKEY_MODEL=<name> clawkey run         # override model for one session

clawkey ralph                            # Ralph + claude (reads PROMPT.md, exits on LOOP_COMPLETE)
CLAWKEY_BACKEND=aider clawkey ralph      # Ralph + aider (talks to Portkey directly, no proxy)

clawkey proxy status                     # is the persistent proxy up?
clawkey proxy logs                       # tail ~/.local/state/clawkey/proxy.log
```

Ralph requires `ralph` (and `aider` for the aider backend); see their respective install docs.

## Configuration

User config lives in XDG-compliant paths:

| Path | Contents |
|---|---|
| `$XDG_CONFIG_HOME/clawkey/.env` *(`~/.config/clawkey/.env`)* | API key, default model, proxy auth key |
| `$XDG_CONFIG_HOME/clawkey/litellm_config.yaml` | Active model list |
| `$XDG_STATE_HOME/clawkey/proxy.log` *(`~/.local/state/clawkey/proxy.log`)* | Persistent-proxy log |

| Env var | Purpose | Default |
|---|---|---|
| `AI_SANDBOX_KEY` | Portkey API key | *required* |
| `PORTKEY_MODEL` | Default model name | *required* |
| `LITELLM_MASTER_KEY` | LiteLLM proxy auth key | auto-rotated by `clawkey config` |
| `LITELLM_PORT` | Proxy port | `4040` |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Output token cap | `16384` |
| `CLAWKEY_BACKEND` | Ralph backend: `claude` or `aider` | `claude` |
| `CLAWKEY_CONFIG_DIR` / `CLAWKEY_STATE_DIR` / `CLAWKEY_ENV_FILE` / `CLAWKEY_MODEL_CONFIG` | Override XDG paths (per-project state, etc.) | XDG defaults |

## Bootstrap a per-project copy

If you'd rather not install globally, `clawkey-init.sh` drops a self-contained copy of `clawkey`, `lib/`, and the configs into a project dir:

```bash
cd ~/my-new-project
~/path/to/clawkey/clawkey-init.sh
./clawkey config
./clawkey run
```

The bootstrapped copy still uses XDG paths — the project dir holds only the script tree.

## Testing

```bash
./test.sh                       # local venv, full pytest run (skips integration without proxy/key)
./test.sh --config              # config-only tests (no deps beyond pytest+pyyaml+requests)
./test.sh --docker              # run inside the docker-compose test service
```

CI runs the full suite on every push (skipping doc-only commits) on a Linux runner with bash 3.2 built and cached to better align with macOS, so compatibility quirks like empty-array expansion under `set -u` are caught upstream.

Test files: `test_claude_config.py`, `test_ralph_config.py`, `test_proxy_subcommand.py`, `test_xdg_migration.py`, `test_install_sh.py` (no credentials needed) and `test_litellm_proxy.py`, `test_portkey_connection.py` (need `AI_SANDBOX_KEY` and a running proxy; skip cleanly otherwise).
