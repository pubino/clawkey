"""Validate clawkey project structure and LiteLLM + Portkey configuration."""

import os
import subprocess

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_clawkey_script_exists():
    script = os.path.join(PROJECT_ROOT, "clawkey")
    assert os.path.exists(script), "clawkey CLI script not found"


def test_clawkey_script_is_executable():
    script = os.path.join(PROJECT_ROOT, "clawkey")
    assert os.access(script, os.X_OK), "clawkey is not executable"


def test_clawkey_run_subcommand_dispatches():
    """clawkey must define `run` and `ralph` subcommands in its top-level dispatcher."""
    script = os.path.join(PROJECT_ROOT, "clawkey")
    with open(script) as f:
        content = f.read()
    assert "    run)" in content, "clawkey must dispatch the 'run' subcommand"
    assert "    ralph)" in content, "clawkey must dispatch the 'ralph' subcommand"
    assert "    proxy)" in content, "clawkey must dispatch the 'proxy' subcommand"


def test_clawkey_help_lists_run_and_proxy():
    """`clawkey help` must mention `run`, `ralph`, and `proxy` so users discover them."""
    script = os.path.join(PROJECT_ROOT, "clawkey")
    out = subprocess.check_output([script, "help"], text=True)
    assert "clawkey run" in out, "help text must mention 'clawkey run'"
    assert "clawkey ralph" in out, "help text must mention 'clawkey ralph'"
    assert "clawkey proxy" in out, "help text must mention 'clawkey proxy'"


def test_runtime_library_exists():
    lib = os.path.join(PROJECT_ROOT, "lib", "clawkey-runtime.sh")
    assert os.path.exists(lib), "lib/clawkey-runtime.sh not found"


def test_runtime_library_exports_anthropic_env():
    """The runtime library must wire ANTHROPIC_AUTH_TOKEN and ANTHROPIC_BASE_URL."""
    lib = os.path.join(PROJECT_ROOT, "lib", "clawkey-runtime.sh")
    with open(lib) as f:
        content = f.read()
    assert "ANTHROPIC_AUTH_TOKEN" in content, (
        "runtime lib must export ANTHROPIC_AUTH_TOKEN for proxy auth"
    )
    assert "ANTHROPIC_BASE_URL" in content, (
        "runtime lib must export ANTHROPIC_BASE_URL pointing at LiteLLM"
    )
    assert "unset ANTHROPIC_API_KEY" in content, (
        "runtime lib must unset ANTHROPIC_API_KEY to avoid key conflicts"
    )


def test_clawkey_does_not_write_settings_json():
    """clawkey must use env vars only — no settings.json side effects."""
    for name in ("clawkey", os.path.join("lib", "clawkey-runtime.sh")):
        path = os.path.join(PROJECT_ROOT, name)
        with open(path) as f:
            content = f.read()
        assert "settings.json" not in content, (
            f"{name} should not write .claude/settings.json — use env vars"
        )


def test_litellm_config_exists():
    config = os.path.join(PROJECT_ROOT, "litellm_config.yaml")
    assert os.path.exists(config), "litellm_config.yaml not found"


def test_litellm_config_valid():
    """litellm_config.yaml must have a model_list key (may be empty before first ./clawkey models --add)."""
    import yaml
    config_path = os.path.join(PROJECT_ROOT, "litellm_config.yaml")
    with open(config_path) as f:
        config = yaml.safe_load(f)
    assert "model_list" in config, "Missing model_list in litellm_config.yaml"
    for model in config.get("model_list") or []:
        assert "model_name" in model, f"Model entry missing model_name: {model}"
        assert "litellm_params" in model, f"Model entry missing litellm_params: {model}"


def test_load_env_exists():
    script = os.path.join(PROJECT_ROOT, "load-env.sh")
    assert os.path.exists(script), "load-env.sh not found"


def test_clawkey_init_does_not_write_settings_json():
    """clawkey-init.sh must not overwrite .claude/settings.json."""
    script = os.path.join(PROJECT_ROOT, "clawkey-init.sh")
    with open(script) as f:
        content = f.read()
    assert "settings.json" not in content, (
        "clawkey-init.sh should not write .claude/settings.json — "
        "it would overwrite the user's existing Claude Code configuration"
    )
