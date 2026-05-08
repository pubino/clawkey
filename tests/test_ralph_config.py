"""Validate Ralph orchestration config and swappable backend setup."""

import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_ralph_yml_exists():
    path = os.path.join(PROJECT_ROOT, "ralph.yml")
    assert os.path.exists(path), "ralph.yml not found"


def test_ralph_yml_has_custom_backend():
    """ralph.yml must use 'custom' backend mode."""
    import yaml

    path = os.path.join(PROJECT_ROOT, "ralph.yml")
    with open(path) as f:
        config = yaml.safe_load(f)
    assert "cli" in config, "Missing 'cli' section in ralph.yml"
    assert config["cli"].get("backend") == "custom", (
        "cli.backend must be 'custom'"
    )


def test_ralph_yml_command_points_to_backend_wrapper():
    """ralph.yml command must point to portkey-backend.sh."""
    import yaml

    path = os.path.join(PROJECT_ROOT, "ralph.yml")
    with open(path) as f:
        config = yaml.safe_load(f)
    command = config["cli"].get("command", "")
    assert "portkey-backend.sh" in command, (
        f"cli.command must reference portkey-backend.sh, got: {command}"
    )


def test_ralph_yml_has_completion_promise():
    """ralph.yml must define LOOP_COMPLETE as completion_promise."""
    import yaml

    path = os.path.join(PROJECT_ROOT, "ralph.yml")
    with open(path) as f:
        config = yaml.safe_load(f)
    assert "event_loop" in config, "Missing 'event_loop' section"
    assert config["event_loop"].get("completion_promise") == "LOOP_COMPLETE", (
        "event_loop.completion_promise must be 'LOOP_COMPLETE'"
    )


def test_portkey_backend_script_exists():
    path = os.path.join(PROJECT_ROOT, "portkey-backend.sh")
    assert os.path.exists(path), "portkey-backend.sh not found"


def test_portkey_backend_script_is_executable():
    path = os.path.join(PROJECT_ROOT, "portkey-backend.sh")
    assert os.access(path, os.X_OK), "portkey-backend.sh is not executable"


def test_portkey_backend_script_supports_claude_and_aider():
    """portkey-backend.sh must handle both claude and aider backends."""
    path = os.path.join(PROJECT_ROOT, "portkey-backend.sh")
    with open(path) as f:
        content = f.read()
    assert "claude)" in content or "claude\")" in content, (
        "portkey-backend.sh must handle claude backend"
    )
    assert "aider)" in content or "aider\")" in content, (
        "portkey-backend.sh must handle aider backend"
    )


def test_prompt_has_loop_complete():
    """PROMPT.md must contain the LOOP_COMPLETE signal."""
    path = os.path.join(PROJECT_ROOT, "PROMPT.md")
    assert os.path.exists(path), "PROMPT.md not found"
    with open(path) as f:
        content = f.read()
    assert "LOOP_COMPLETE" in content, (
        "PROMPT.md must contain LOOP_COMPLETE completion signal"
    )


def test_clawkey_ralph_subcommand_resolves_ralph_yml():
    """The clawkey ralph subcommand must look for ralph.yml in caller dir then CLAWKEY_DIR."""
    script = os.path.join(PROJECT_ROOT, "clawkey")
    with open(script) as f:
        content = f.read()
    assert "cmd_ralph" in content, "clawkey must define cmd_ralph"
    # caller dir → CLAWKEY_DIR fallback
    assert "_caller_dir}/ralph.yml" in content, (
        "cmd_ralph must check caller dir for ralph.yml"
    )
    assert "CLAWKEY_DIR}/ralph.yml" in content, (
        "cmd_ralph must fall back to CLAWKEY_DIR/ralph.yml"
    )


def test_clawkey_ralph_supports_claude_and_aider_backends():
    """cmd_ralph must dispatch on CLAWKEY_BACKEND for both claude and aider."""
    script = os.path.join(PROJECT_ROOT, "clawkey")
    with open(script) as f:
        content = f.read()
    # Restrict the search to the cmd_ralph function body.
    start = content.index("cmd_ralph()")
    end = content.index("# ──", start)
    body = content[start:end]
    assert "claude)" in body, "cmd_ralph must handle claude backend"
    assert "aider)" in body, "cmd_ralph must handle aider backend"
