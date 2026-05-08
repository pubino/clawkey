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


def test_proxy_install_refuses_tcc_protected_dirs():
    """cmd_proxy_install must refuse to install when CLAWKEY_DIR is under a
    TCC-protected dir — launchd-spawned processes can't read those paths,
    so the daemon would silently fail."""
    script = (PROJECT_ROOT / "clawkey").read_text()
    install_block = script[script.index("cmd_proxy_install()") : script.index("cmd_proxy_uninstall()")]
    for protected in ("$HOME/Downloads", "$HOME/Documents", "$HOME/Desktop"):
        assert protected in install_block, (
            f"cmd_proxy_install must check for {protected} (TCC-protected)"
        )
    # Must short-circuit before the bootstrap call.
    tcc_idx = install_block.index('"$HOME/Downloads"/*')
    bootstrap_idx = install_block.index("launchctl bootstrap")
    assert tcc_idx < bootstrap_idx, "TCC check must run before launchctl bootstrap"


def test_run_proxy_hints_when_venv_relocated():
    """run-proxy.sh must hint that the venv may have been relocated when
    activate succeeds but litellm isn't on PATH afterwards (a common dev
    foot-gun: moving the checkout breaks the venv's hardcoded shebangs)."""
    wrapper = (PROJECT_ROOT / "lib" / "launchd" / "run-proxy.sh").read_text()
    assert "relocated" in wrapper, (
        "run-proxy.sh must distinguish a relocated venv from a missing one"
    )
    assert "rm -rf .venv" in wrapper, (
        "run-proxy.sh must include a rebuild recipe in its error hint"
    )


def test_cmd_proxy_reload_waits_for_health():
    """After kickstart, cmd_proxy_reload must wait for /health to recover so
    a follow-up `proxy status` doesn't race with daemon rebind."""
    script = (PROJECT_ROOT / "clawkey").read_text()
    reload_block = script[script.index("cmd_proxy_reload()") : script.index("cmd_proxy_status()")]
    assert "clawkey_proxy_wait_running" in reload_block, (
        "cmd_proxy_reload must call clawkey_proxy_wait_running after kickstart"
    )


def test_proxy_reload_if_loaded_waits_for_health():
    """The reload-on-config-edit path must also wait so subsequent status
    calls in the same flow report accurately."""
    lib = (PROJECT_ROOT / "lib" / "clawkey-runtime.sh").read_text()
    fn = lib[lib.index("clawkey_proxy_reload_if_loaded()") : lib.index("clawkey_proxy_wait_running()")]
    assert "clawkey_proxy_wait_running" in fn, (
        "reload_if_loaded must wait for health after kickstart"
    )


def test_requirements_litellm_floor_pulls_python314_compatible_orjson():
    """litellm[proxy]>=1.40 resolves to a litellm whose orjson pin (==3.10.15)
    has no cp314 wheels — installs blow up on Python 3.14 boxes. Pin the floor
    high enough that pip resolves to a litellm whose orjson pin (==3.11.6+)
    ships cp314 wheels."""
    reqs = (PROJECT_ROOT / "requirements.txt").read_text()
    m = re.search(r"^\s*litellm\[proxy\]\s*>=\s*(\d+)\.(\d+)", reqs, re.MULTILINE)
    assert m, "requirements.txt must pin litellm[proxy] with a >= floor"
    major, minor = int(m.group(1)), int(m.group(2))
    assert (major, minor) >= (1, 75), (
        f"litellm[proxy] floor {major}.{minor} is too low — pre-1.75 releases "
        f"pin orjson<3.11, which has no Python 3.14 wheels"
    )


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
