"""Validate clawkey project structure and LiteLLM + Portkey configuration."""

import os
import pytest

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_run_script_exists():
    script = os.path.join(PROJECT_ROOT, "run.sh")
    assert os.path.exists(script), "run.sh not found"


def test_run_script_is_executable():
    script = os.path.join(PROJECT_ROOT, "run.sh")
    assert os.access(script, os.X_OK), "run.sh is not executable"


def test_litellm_config_exists():
    config = os.path.join(PROJECT_ROOT, "litellm_config.yaml")
    assert os.path.exists(config), "litellm_config.yaml not found"


def test_setup_env_exists():
    setup = os.path.join(PROJECT_ROOT, "setup-env.sh")
    assert os.path.exists(setup), "setup-env.sh not found"


def test_run_script_exports_anthropic_auth_token():
    """run.sh must export ANTHROPIC_AUTH_TOKEN (not ANTHROPIC_API_KEY)."""
    script = os.path.join(PROJECT_ROOT, "run.sh")
    with open(script) as f:
        content = f.read()
    assert "ANTHROPIC_AUTH_TOKEN" in content, (
        "run.sh must export ANTHROPIC_AUTH_TOKEN for proxy auth"
    )
    assert "ANTHROPIC_BASE_URL" in content, (
        "run.sh must export ANTHROPIC_BASE_URL pointing at LiteLLM"
    )


def test_run_script_does_not_write_settings_json():
    """run.sh should use env vars only — no settings.json side effects."""
    script = os.path.join(PROJECT_ROOT, "run.sh")
    with open(script) as f:
        content = f.read()
    assert "settings.json" not in content, (
        "run.sh should not write .claude/settings.json — use env vars for clean switching"
    )


def test_litellm_config_has_models():
    """litellm_config.yaml must define at least one model."""
    import yaml
    config_path = os.path.join(PROJECT_ROOT, "litellm_config.yaml")
    with open(config_path) as f:
        config = yaml.safe_load(f)
    assert "model_list" in config, "Missing model_list in litellm_config.yaml"
    assert len(config["model_list"]) > 0, "model_list is empty"
    for model in config["model_list"]:
        assert "model_name" in model, f"Model entry missing model_name: {model}"
        assert "litellm_params" in model, f"Model entry missing litellm_params: {model}"


def test_clawkey_script_exists():
    script = os.path.join(PROJECT_ROOT, "clawkey")
    assert os.path.exists(script), "clawkey management script not found"


def test_clawkey_script_is_executable():
    script = os.path.join(PROJECT_ROOT, "clawkey")
    assert os.access(script, os.X_OK), "clawkey is not executable"


def test_clawkey_init_does_not_write_settings_json():
    """clawkey-init.sh must not overwrite .claude/settings.json."""
    script = os.path.join(PROJECT_ROOT, "clawkey-init.sh")
    with open(script) as f:
        content = f.read()
    assert "settings.json" not in content, (
        "clawkey-init.sh should not write .claude/settings.json — "
        "it would overwrite the user's existing Claude Code configuration"
    )
