# Security

## Threat model

Clawkey is a local-first developer tool. It writes to the user's home directory only and binds a single TCP listener to `127.0.0.1`. It does not:

- run as root or use `sudo` anywhere
- bind any network interface other than loopback
- read or write the user's regular Claude Code config (`~/.claude/`, project `.claude/`, `ANTHROPIC_API_KEY`)
- emit telemetry or beacons

The interesting attack surfaces are: secret files on disk, the curl-pipe-bash installer, the persistent-proxy daemon (macOS only), and the GitHub Actions configuration.

## Secrets at rest

| File | Mode | Owner |
|---|---|---|
| `$XDG_CONFIG_HOME/clawkey/.env` | `0600` | user |
| `$XDG_CONFIG_HOME/clawkey/litellm_config.yaml` | default umask | user |
| `$XDG_STATE_HOME/clawkey/proxy.log` | default umask | user |
| `~/Library/LaunchAgents/com.clawkey.proxy.plist` | default umask | user |

Only `.env` contains secrets (`AI_SANDBOX_KEY`, `LITELLM_MASTER_KEY`). `clawkey config`, `clawkey config --clear`, and the legacy-layout migration all `chmod 0600` after writing. The `litellm_config.yaml` holds only the model list; the launchd plist holds only paths and the port number — neither contains credentials. The proxy reads `LITELLM_MASTER_KEY` from `.env` at startup, never via command line.

## LITELLM_MASTER_KEY

Generated as `sk-clawkey-` + 24 random bytes (192 bits) from `openssl rand -hex 24`. Rotated automatically by `clawkey config` whenever the existing key matches the legacy default `sk-clawkey-local`, and on every `clawkey config --clear`. The persistent daemon picks up the new value on the next `clawkey proxy reload` (which `clawkey config` calls automatically when the agent is loaded).

## Persistent-proxy scope

The launchd plist is installed to `~/Library/LaunchAgents/` and bootstrapped into the `gui/$UID` domain. Both operations work without `sudo` and are confined to the invoking user's session. The proxy's listener stays on `127.0.0.1:4040` — the plist passes `--host 127.0.0.1` to litellm explicitly. CI tests assert these invariants in `tests/test_proxy_subcommand.py`.

`/Library/LaunchDaemons/` (system scope, requires root) is **never** used.

## Curl-pipe-bash installer

`install.sh` is the standard "trust on first download" pattern. The script runs as the invoking user, writes only to `$XDG_DATA_HOME/clawkey` and `$HOME/.local/bin`, and calls `pip install` inside a venv it owns. Mitigations available to users:

1. **Pin a release** instead of fetching latest:
   ```bash
   CLAWKEY_REF=v0.1.0 bash <(curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh)
   ```
2. **Review before piping**:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/pubino/clawkey/main/install.sh > install.sh
   less install.sh
   bash install.sh
   ```
3. **Verify the source repo** — ensure you're hitting `pubino/clawkey`, not a fork or impersonator.

Signed releases or SHA-256 checksums are not currently published. If that becomes a hard requirement, see `PLAN.md`.

## GitHub Actions

- Workflows scope `permissions: contents: read` (test) or `contents: write` (release, for publishing release assets only).
- The `e2e` job gates on the `AI_SANDBOX_KEY` repo secret; PRs from forks (which do not see the secret) skip cleanly with a notice.
- The `e2e` job never echoes the secret to the log (verified manually and statically). It writes the secret into `~/.config/clawkey/.env` after `umask 077` so the file lands at `0600` on the runner. The runner is destroyed at job end.
- Reusable actions are pinned by major tag (`actions/checkout@v6`, etc.). SHA-pinning is a defense-in-depth measure not currently applied; trade-off is more maintenance vs. protection against compromised action releases. Open question for future work.

## Reporting

Open a GitHub issue at <https://github.com/pubino/clawkey/issues> or email the maintainer for non-public reports. There is no embargoed disclosure process at this time.

## Known limitations

- No checksum verification on the install tarball (see "Curl-pipe-bash" above).
- Action SHA pinning not in use.
- Tarball extraction uses `tar -xz --strip-components=1` without `--no-same-owner`; modern tar implementations reject `..` paths but a hardened option could be added.
- The litellm Python dependency tree (transitively ~100 packages) is not audited per release; we trust upstream maintainers and PyPI.
