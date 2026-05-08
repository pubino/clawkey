"""Behavior tests for the top-level `clawkey` CLI dispatcher.

These exercise the script with sandboxed XDG paths so the developer's
real config and state are never touched.
"""

import os
import subprocess
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CLAWKEY = PROJECT_ROOT / "clawkey"


# Minimal valid litellm config the runtime treats as "1 model is configured".
ONE_MODEL_CONFIG = (
    "model_list:\n"
    "  - model_name: claude-opus-4-7\n"
    "    litellm_params:\n"
    "      model: openai/claude-opus-4-7\n"
    "      api_base: https://api.portkey.ai/v1\n"
    "      api_key: os.environ/AI_SANDBOX_KEY\n"
    "general_settings:\n"
    '  master_key: "os.environ/LITELLM_MASTER_KEY"\n'
)

EMPTY_MODEL_CONFIG = (
    "model_list: []\n"
    "general_settings:\n"
    '  master_key: "os.environ/LITELLM_MASTER_KEY"\n'
)


def _sandbox_env(tmp_path, *, model_config=EMPTY_MODEL_CONFIG, env_body=None):
    """Build (env, paths) for a sandboxed clawkey invocation."""
    config_dir = tmp_path / "config"
    state_dir = tmp_path / "state"
    home = tmp_path / "home"
    config_dir.mkdir()
    state_dir.mkdir()
    home.mkdir()

    env_file = config_dir / ".env"
    model_config_path = config_dir / "litellm_config.yaml"

    if env_body is None:
        env_body = "AI_SANDBOX_KEY=sk-test\nLITELLM_MASTER_KEY=sk-clawkey-test\n"
    env_file.write_text(env_body)
    env_file.chmod(0o600)
    model_config_path.write_text(model_config)

    env = os.environ.copy()
    env["HOME"] = str(home)
    env["CLAWKEY_CONFIG_DIR"] = str(config_dir)
    env["CLAWKEY_STATE_DIR"] = str(state_dir)
    env["CLAWKEY_ENV_FILE"] = str(env_file)
    env["CLAWKEY_MODEL_CONFIG"] = str(model_config_path)
    return env, env_file, model_config_path


# ── 1 model = assumed default ──────────────────────────────────────


def test_models_add_auto_sets_default_when_unset(tmp_path):
    """Adding a model when PORTKEY_MODEL is unset must populate it.

    Regression: a fresh user runs `clawkey config` (cmd_config can't
    write PORTKEY_MODEL when no models exist), then `clawkey models
    --add foo`, then `clawkey run` — and used to dead-end with
    "PORTKEY_MODEL is not set". Adding the first model auto-sets it.
    """
    env, env_file, _ = _sandbox_env(tmp_path)

    result = subprocess.run(
        ["bash", str(CLAWKEY), "models", "--add"],
        env=env,
        input="claude-opus-4-7\n",
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout

    new_env = env_file.read_text()
    assert "PORTKEY_MODEL=claude-opus-4-7" in new_env, new_env
    # Must not clobber unrelated lines.
    assert "AI_SANDBOX_KEY=sk-test" in new_env, new_env
    assert "LITELLM_MASTER_KEY=sk-clawkey-test" in new_env, new_env


def test_models_add_does_not_change_default_when_already_set(tmp_path):
    """Adding a second model must NOT overwrite an existing PORTKEY_MODEL."""
    env, env_file, _ = _sandbox_env(
        tmp_path,
        model_config=ONE_MODEL_CONFIG,
        env_body=(
            "AI_SANDBOX_KEY=sk-test\n"
            "PORTKEY_MODEL=claude-opus-4-7\n"
            "LITELLM_MASTER_KEY=sk-clawkey-test\n"
        ),
    )

    result = subprocess.run(
        ["bash", str(CLAWKEY), "models", "--add"],
        env=env,
        input="another-model\n",
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    assert "PORTKEY_MODEL=claude-opus-4-7" in env_file.read_text()


def test_startup_self_heal_adopts_only_model_as_default(tmp_path):
    """Any clawkey invocation with a configured single model and no
    PORTKEY_MODEL must adopt it. `clawkey help` is a side-effect-free
    way to trigger the self-heal step."""
    env, env_file, _ = _sandbox_env(tmp_path, model_config=ONE_MODEL_CONFIG)
    # Pre-condition: env has no PORTKEY_MODEL.
    assert "PORTKEY_MODEL=" not in env_file.read_text()

    result = subprocess.run(
        ["bash", str(CLAWKEY), "help"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    assert "PORTKEY_MODEL=claude-opus-4-7" in env_file.read_text()


def test_startup_self_heal_skipped_for_uninstall(tmp_path):
    """Maintenance subcommands must not mutate .env on the way out — the
    self-heal write would race with `install.sh uninstall`'s rm of the
    config dir under --purge."""
    script = CLAWKEY.read_text()
    # Locate the self-heal block.
    idx = script.index("Self-heal: if no default model is set")
    end = script.index("esac", idx)
    block = script[idx:end]
    assert "update|reinstall|uninstall" in block, (
        "self-heal must skip the maintenance subcommands"
    )


# ── Maintenance: clawkey update / reinstall / uninstall ────────────


def test_help_lists_maintenance_subcommands():
    """`clawkey help` must surface update/reinstall/uninstall — install.sh
    has them, but a user who already installed only knows the `clawkey`
    binary, so they need to be discoverable here."""
    result = subprocess.run(
        ["bash", str(CLAWKEY), "help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0
    out = result.stdout
    assert "clawkey update" in out
    assert "clawkey reinstall" in out
    assert "clawkey uninstall" in out


def test_maintenance_subcommands_delegate_to_install_sh():
    """update/reinstall/uninstall must exec the locally-installed install.sh
    so the maintenance flow matches the canonical curl-pipe-bash one-liner
    rather than reimplementing tarball fetch + rsync inside clawkey."""
    script = CLAWKEY.read_text()

    for fn, expected_arg in [
        ("cmd_update()", "install"),
        ("cmd_reinstall()", "reinstall"),
        ("cmd_uninstall()", "uninstall"),
    ]:
        start = script.index(fn)
        end = script.index("\n}\n", start)
        body = script[start:end]
        assert "exec bash" in body, f"{fn} must exec install.sh"
        assert f"install.sh\" {expected_arg}" in body, (
            f"{fn} must invoke install.sh {expected_arg}, body was:\n{body}"
        )


def test_uninstall_passes_through_purge_flag():
    """`clawkey uninstall --purge` must forward --purge to install.sh."""
    script = CLAWKEY.read_text()
    # cmd_uninstall is invoked from dispatch with the rest of argv shifted.
    dispatch_uninstall = script[script.index("    uninstall)\n") : script.index("    help|")]
    assert "shift" in dispatch_uninstall
    assert 'cmd_uninstall "$@"' in dispatch_uninstall

    body_start = script.index("cmd_uninstall()")
    body_end = script.index("\n}\n", body_start)
    body = script[body_start:body_end]
    # The shell idiom ${1+"$@"} is what survives bash 3.2 + set -u with an
    # empty argv. ${@:+"$@"} or "$@" alone would expand to "" under set -u
    # in 3.2, breaking the no-flag case.
    assert '${1+"$@"}' in body, (
        "cmd_uninstall must forward argv with the bash 3.2-safe ${1+\"$@\"} idiom"
    )
