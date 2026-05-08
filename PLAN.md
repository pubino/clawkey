# Planned work

A scratch pad for ideas that haven't been picked up yet. Not a roadmap commitment — items here move to a real PR or get dropped.

---

## Docker distribution

### Why

- **Cross-platform persistent proxy.** Today the persistent proxy is macOS-only (launchd). Linux users either run `clawkey run` ephemerally each time (~30 s cold start) or maintain their own systemd unit. Windows users have no equivalent at all. A containerised proxy gives all three platforms feature parity with `clawkey proxy install`.
- **Lock-down friendly.** Some users can't install Python or Node globally on their machines. A container removes those install steps.
- **Reproducibility.** The pinned image fixes litellm + transitive deps to a specific resolution. Saves debugging "works on my box" issues across users.

### Three modes, increasing in scope

#### Mode 1 — Sidecar proxy (recommended starting point)

Promote the existing `docker-compose.yml` `litellm` service into a user-facing entry point. New file at the repo root: `docker-compose.proxy.yml` (or rename / split the current one). User runs:

```bash
docker compose -f docker-compose.proxy.yml up -d   # starts background proxy
docker compose -f docker-compose.proxy.yml down    # stops it
clawkey run                                        # talks to localhost:4040 like always
```

**Files needed**

- `docker-compose.proxy.yml` — `litellm` service bound to `127.0.0.1:4040:4040`, mounting `~/.config/clawkey/litellm_config.yaml` read-only and reading `~/.config/clawkey/.env` for env. Health check on `/health` (already in current compose file).
- A short README section (≤10 lines) explaining when to use this vs. `clawkey proxy install`.
- Optional: `clawkey proxy install` could detect non-Darwin and emit a hint pointing at the compose file instead of erroring out.

**Why this first**

- ~60 lines of YAML, zero new code.
- Doesn't require publishing an image to a registry — uses the official `docker.litellm.ai/berriai/litellm:main-latest` image already pinned in the existing compose file.
- Solves the cross-platform persistent-proxy gap without changing any clawkey runtime behaviour.

#### Mode 2 — All-in-one container

A `Dockerfile` that bundles Claude Code + clawkey + the venv. Image published to `ghcr.io/pubino/clawkey:<tag>`. End-user flow:

```bash
docker run -it --rm \
    -v "$PWD":/workspace -w /workspace \
    -v ~/.config/clawkey:/home/clawkey/.config/clawkey \
    -v ~/.local/state/clawkey:/home/clawkey/.local/state/clawkey \
    ghcr.io/pubino/clawkey:latest run
```

**Trade-offs**

- Removes *every* host-side install step.
- Image is large (~500 MB: python:3.12-slim + node + npm + claude-code + venv).
- Bind-mounting `$PWD` covers file editing inside the agent loop, but you lose `git config --global user.email`-style personal config unless you also mount `~/.gitconfig`. Lots of bind mounts get ugly fast.
- Interactive-TTY edge cases — Claude Code's UI assumes a real terminal; works in `docker run -it` but is finicky in some terminal multiplexers.
- Need a CI workflow to publish the image on tag (would extend `.github/workflows/release.yml`).

**Verdict**: real value for users who already containerise everything, but heavier than Mode 1 and meaningfully more maintenance.

#### Mode 3 — Dev / CI image

A `Dockerfile.dev` that's the test environment: bash 3.2.57, Python 3.12, Node 20, the lot. Useful for contributors who want to reproduce CI exactly and for the `docker-compose run --rm test` path that already exists.

**Trade-offs**

- Mostly a contributor-comfort feature, not a user-facing one.
- Could replace the on-the-fly bash 3.2 build in CI by using a pre-baked image. Saves ~60 s when the cache misses; otherwise no benefit.

**Verdict**: nice-to-have for repo hygiene; low pull from users.

### Recommendation

Build Mode 1 first as a small, isolated PR. Skip Mode 2 unless someone asks for it. Skip Mode 3 unless contributor friction becomes a real complaint.

### Implementation sketch for Mode 1

```yaml
# docker-compose.proxy.yml
services:
  proxy:
    image: docker.litellm.ai/berriai/litellm:main-latest
    container_name: clawkey-proxy
    restart: unless-stopped
    ports:
      - "127.0.0.1:4040:4040"
    volumes:
      - ${HOME}/.config/clawkey/litellm_config.yaml:/app/config.yaml:ro
    env_file:
      - ${HOME}/.config/clawkey/.env
    command: ["--config", "/app/config.yaml", "--port", "4040", "--host", "0.0.0.0"]
    healthcheck:
      test: ["CMD-SHELL", "curl -sf -H \"Authorization: Bearer $$LITELLM_MASTER_KEY\" http://localhost:4040/health"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s
```

Then a small README addition:

```markdown
### Persistent proxy (Linux / Windows / macOS-without-launchd)

If you'd rather not use launchd, run the proxy as a Docker sidecar:

    docker compose -f docker-compose.proxy.yml up -d
    docker compose -f docker-compose.proxy.yml down

`clawkey run` talks to `localhost:4040` regardless of how the proxy is hosted.
```

Open question: should `clawkey proxy install` on Linux print this hint instead of failing with the current `requires macOS` message? Probably yes; one-line change.

### Open questions

- Do users want `ghcr.io/pubino/clawkey` published on every release, or only on demand?
- Does Princeton's network gating (the same one that breaks live-inference in CI on hosted runners) also break the LiteLLM container if it runs on a non-allowlisted machine? If yes, a Docker proxy doesn't help there either.
- Compose v1 (`docker-compose`) vs v2 (`docker compose`) — most users have v2 now, but the project's existing docs show `docker-compose run` (v1 syntax). Pick one and standardise.
