"""Validate the persistent-proxy subcommand and launchd template."""

import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def test_runtime_lib_uses_user_scope_paths():
    """The runtime lib must use XDG-compliant user-scope paths and the plist
    must go under ~/Library/LaunchAgents (user scope) — never /Library/LaunchDaemons."""
    lib = (PROJECT_ROOT / "lib" / "clawkey-runtime.sh").read_text()
    assert "XDG_CONFIG_HOME" in lib, "config dir must respect XDG_CONFIG_HOME"
    assert "XDG_STATE_HOME" in lib, "state dir must respect XDG_STATE_HOME"
    assert "$HOME/.config" in lib, "config dir must default to $HOME/.config/clawkey"
    assert "$HOME/.local/state" in lib, "state dir must default to $HOME/.local/state/clawkey"
    assert "Library/LaunchAgents" in lib, "plist path must be Library/LaunchAgents"
    assert "/Library/LaunchDaemons" not in lib, (
        "must not reference system-scope LaunchDaemons (would require sudo)"
    )


def test_clawkey_proxy_install_uses_gui_domain_no_sudo():
    """Install path must target gui/$UID and never call sudo."""
    script = (PROJECT_ROOT / "clawkey").read_text()
    install_block = script[script.index("cmd_proxy_install()") : script.index("cmd_proxy_uninstall()")]
    assert "gui/$(id -u)" in install_block, "must bootstrap into gui/$UID domain"
    assert "sudo" not in install_block, "install path must not invoke sudo"


def test_clawkey_proxy_uninstall_idempotent_no_sudo():
    script = (PROJECT_ROOT / "clawkey").read_text()
    body = script[script.index("cmd_proxy_uninstall()") : script.index("cmd_proxy_start()")]
    assert "sudo" not in body, "uninstall path must not invoke sudo"
    assert "bootout" in body, "uninstall must call launchctl bootout"


def test_plist_template_exists_and_is_well_formed():
    template = PROJECT_ROOT / "lib" / "launchd" / "com.clawkey.proxy.plist.in"
    assert template.exists(), "plist template missing"
    raw = template.read_text()
    # Render with safe substitutions and parse as plist.
    config_dir = Path.home() / ".config" / "clawkey"
    state_dir = Path.home() / ".local" / "state" / "clawkey"
    rendered = (
        raw.replace("{{CLAWKEY_DIR}}", str(PROJECT_ROOT))
           .replace("{{CLAWKEY_CONFIG_DIR}}", str(config_dir))
           .replace("{{CLAWKEY_STATE_DIR}}", str(state_dir))
           .replace("{{LITELLM_PORT}}", "4040")
           .replace("{{LOG_PATH}}", str(state_dir / "proxy.log"))
    )
    # All placeholders must have been substituted.
    assert "{{" not in rendered, f"unsubstituted placeholder in plist: {rendered}"
    parsed = plistlib.loads(rendered.encode())
    assert parsed["Label"] == "com.clawkey.proxy"
    assert parsed["RunAtLoad"] is True
    assert parsed["KeepAlive"]["Crashed"] is True
    assert parsed["EnvironmentVariables"]["CLAWKEY_DIR"] == str(PROJECT_ROOT)
    assert parsed["EnvironmentVariables"]["CLAWKEY_CONFIG_DIR"] == str(config_dir)
    assert parsed["EnvironmentVariables"]["CLAWKEY_STATE_DIR"] == str(state_dir)
    assert parsed["ProgramArguments"][0].endswith("lib/launchd/run-proxy.sh")


def test_run_proxy_wrapper_executable_and_syntactically_valid():
    wrapper = PROJECT_ROOT / "lib" / "launchd" / "run-proxy.sh"
    assert wrapper.exists(), "run-proxy.sh missing"
    assert os.access(wrapper, os.X_OK), "run-proxy.sh is not executable"
    subprocess.check_call(["bash", "-n", str(wrapper)])


def test_proxy_status_runs_when_uninstalled(tmp_path, monkeypatch):
    """`clawkey proxy status` must succeed even with no plist installed."""
    # Run with HOME redirected so we don't depend on whether the user has
    # actually installed the agent.
    home = tmp_path / "home"
    home.mkdir()
    env = os.environ.copy()
    env["HOME"] = str(home)
    # Don't let an existing $LITELLM_MASTER_KEY change the output shape.
    env.pop("LITELLM_MASTER_KEY", None)
    result = subprocess.run(
        [str(PROJECT_ROOT / "clawkey"), "proxy", "status"],
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, (
        f"proxy status failed: stdout={result.stdout!r} stderr={result.stderr!r}"
    )
    # Strip ANSI for assertion.
    plain = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    if sys.platform == "darwin":
        assert "Plist" in plain
        assert "launchd" in plain
    else:
        assert "macOS-only" in plain or "macOS" in plain
