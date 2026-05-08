"""End-to-end tests for install.sh.

Builds a tarball from the current working tree, then runs install.sh against
that tarball in a hermetic temp HOME so the developer's real install isn't
touched. CLAWKEY_SKIP_VENV=1 keeps the tests fast (no pip install).
"""

import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = PROJECT_ROOT / "install.sh"


# ── Fixtures ────────────────────────────────────────────────────────


@pytest.fixture
def source_tarball(tmp_path_factory):
    """Pack the working tree into a tarball laid out the same way GitHub's
    /archive/<ref>.tar.gz returns: a single top-level directory whose contents
    are the project files. install.sh strips the leading component."""
    pack = tmp_path_factory.mktemp("pack")
    tarball = pack / "clawkey.tar.gz"
    skip_dirs = {".git", ".venv", ".pytest_cache", "__pycache__", "node_modules"}
    skip_files = {".DS_Store"}

    def _filter(tarinfo: tarfile.TarInfo):
        rel = Path(tarinfo.name).parts
        if any(part in skip_dirs for part in rel):
            return None
        if Path(tarinfo.name).name in skip_files:
            return None
        return tarinfo

    with tarfile.open(tarball, "w:gz") as tar:
        # The archive must have a single top-level dir like "clawkey-main/"
        # so install.sh can --strip-components=1.
        tar.add(PROJECT_ROOT, arcname="clawkey-source", filter=_filter)
    return tarball


@pytest.fixture
def sandbox(tmp_path):
    """A clean HOME with empty XDG dirs."""
    home = tmp_path / "home"
    home.mkdir()
    return home


def _run(installer_args, *, sandbox, tarball=None, extra_env=None):
    env = os.environ.copy()
    env["HOME"] = str(sandbox)
    env["CLAWKEY_SKIP_VENV"] = "1"
    # Pin all XDG dirs into the sandbox.
    env["XDG_DATA_HOME"] = str(sandbox / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(sandbox / ".config")
    env["XDG_STATE_HOME"] = str(sandbox / ".local" / "state")
    env["CLAWKEY_BIN_DIR"] = str(sandbox / ".local" / "bin")
    if tarball is not None:
        env["CLAWKEY_TARBALL"] = str(tarball)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(INSTALL_SH), *installer_args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


# ── Tests ───────────────────────────────────────────────────────────


def test_install_layout(source_tarball, sandbox):
    result = _run([], sandbox=sandbox, tarball=source_tarball)
    assert result.returncode == 0, result.stderr or result.stdout

    install_dir = sandbox / ".local" / "share" / "clawkey"
    bin_dir = sandbox / ".local" / "bin"

    assert (install_dir / "clawkey").is_file()
    assert (install_dir / "lib" / "clawkey-runtime.sh").is_file()
    assert (install_dir / "lib" / "launchd" / "com.clawkey.proxy.plist.in").is_file()
    assert (install_dir / "lib" / "launchd" / "run-proxy.sh").is_file()
    assert os.access(install_dir / "clawkey", os.X_OK)
    assert os.access(install_dir / "lib" / "launchd" / "run-proxy.sh", os.X_OK)

    symlink = bin_dir / "clawkey"
    assert symlink.is_symlink()
    assert symlink.resolve() == (install_dir / "clawkey").resolve()


def test_installed_clawkey_runs_help(source_tarball, sandbox):
    """The installed binary must work (i.e. find lib/clawkey-runtime.sh next to it)."""
    _run([], sandbox=sandbox, tarball=source_tarball)
    bin_path = sandbox / ".local" / "bin" / "clawkey"

    env = os.environ.copy()
    env["HOME"] = str(sandbox)
    env["XDG_CONFIG_HOME"] = str(sandbox / ".config")
    env["XDG_STATE_HOME"] = str(sandbox / ".local" / "state")
    result = subprocess.run(
        [str(bin_path), "help"], env=env, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
    plain = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    assert "clawkey run" in plain
    assert "clawkey proxy" in plain


def test_update_is_idempotent(source_tarball, sandbox):
    """A second install over the top must succeed without errors."""
    first = _run([], sandbox=sandbox, tarball=source_tarball)
    assert first.returncode == 0
    second = _run(["update"], sandbox=sandbox, tarball=source_tarball)
    assert second.returncode == 0, second.stderr or second.stdout


def test_reinstall_replaces_install_dir(source_tarball, sandbox):
    _run([], sandbox=sandbox, tarball=source_tarball)
    install_dir = sandbox / ".local" / "share" / "clawkey"
    # Drop a bogus file that should not survive reinstall.
    sentinel = install_dir / "stale.txt"
    sentinel.write_text("from a previous install")

    result = _run(["reinstall"], sandbox=sandbox, tarball=source_tarball)
    assert result.returncode == 0
    assert not sentinel.exists(), "reinstall should wipe the install dir"
    assert (install_dir / "clawkey").is_file()


def test_uninstall_keeps_user_state_by_default(source_tarball, sandbox):
    _run([], sandbox=sandbox, tarball=source_tarball)
    # Simulate user state.
    config_dir = sandbox / ".config" / "clawkey"
    state_dir = sandbox / ".local" / "state" / "clawkey"
    config_dir.mkdir(parents=True)
    (config_dir / ".env").write_text("AI_SANDBOX_KEY=abc\n")
    state_dir.mkdir(parents=True)
    (state_dir / "proxy.log").write_text("hi\n")

    result = _run(["uninstall"], sandbox=sandbox, tarball=source_tarball)
    assert result.returncode == 0

    install_dir = sandbox / ".local" / "share" / "clawkey"
    assert not install_dir.exists()
    assert not (sandbox / ".local" / "bin" / "clawkey").exists()
    assert (config_dir / ".env").exists(), "config should survive plain uninstall"
    assert (state_dir / "proxy.log").exists(), "state should survive plain uninstall"


def test_uninstall_purge_removes_user_state(source_tarball, sandbox):
    _run([], sandbox=sandbox, tarball=source_tarball)
    config_dir = sandbox / ".config" / "clawkey"
    state_dir = sandbox / ".local" / "state" / "clawkey"
    config_dir.mkdir(parents=True)
    (config_dir / ".env").write_text("AI_SANDBOX_KEY=abc\n")
    state_dir.mkdir(parents=True)
    (state_dir / "proxy.log").write_text("hi\n")

    result = _run(["uninstall", "--purge"], sandbox=sandbox, tarball=source_tarball)
    assert result.returncode == 0
    assert not config_dir.exists(), "config should be purged with --purge"
    assert not state_dir.exists(), "state should be purged with --purge"


def test_uninstall_when_not_installed_is_no_op(sandbox):
    """`uninstall` without a prior install should exit cleanly, not error."""
    result = _run(["uninstall"], sandbox=sandbox)
    assert result.returncode == 0, result.stderr or result.stdout


def test_install_rejects_unsupported_python(source_tarball, sandbox, tmp_path):
    """install.sh must refuse a CLAWKEY_PYTHON outside [3.10, 3.13].

    Default `python3` on modern macOS is 3.14, which orjson can't build a
    wheel for; without this check, install.sh hits a Rust-compile failure
    50 transitive deps deep. CLAWKEY_PYTHON is the user-visible escape
    hatch, so it needs the same range check the auto-detect path uses.
    """
    fake = tmp_path / "python3.99"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$*\" in\n"
        "  *sys.version_info*) echo '3.99' ;;\n"
        "  *sys.executable*)   echo \"$0\" ;;\n"
        "  *) ;;\n"
        "esac\n"
    )
    fake.chmod(0o755)

    result = _run(
        [],
        sandbox=sandbox,
        tarball=source_tarball,
        extra_env={"CLAWKEY_PYTHON": str(fake)},
    )
    assert result.returncode != 0
    combined = result.stderr + result.stdout
    assert "3.99" in combined, combined
    assert "3.10" in combined and "3.13" in combined, combined


def test_install_picks_versioned_python_over_default(source_tarball, sandbox, tmp_path, monkeypatch):
    """When `python3` is too new but `python3.13` exists, install.sh must
    pick the versioned binary instead of failing.

    Builds a fake PATH with both: a `python3` that reports 3.99 (rejected)
    and a `python3.13` that reports 3.13 (accepted). With CLAWKEY_SKIP_VENV=1
    we don't actually invoke the interpreter; we only need install.sh to
    reach the success branch without erroring on Python detection.
    """
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()

    too_new = bin_dir / "python3"
    too_new.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$*\" in\n"
        "  *sys.version_info*) echo '3.99' ;;\n"
        "  *sys.executable*)   echo \"$0\" ;;\n"
        "  *) ;;\n"
        "esac\n"
    )
    too_new.chmod(0o755)

    in_range = bin_dir / "python3.13"
    in_range.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$*\" in\n"
        "  *sys.version_info*) echo '3.13' ;;\n"
        "  *sys.executable*)   echo \"$0\" ;;\n"
        "  *) ;;\n"
        "esac\n"
    )
    in_range.chmod(0o755)

    # Hermetic PATH: only our fakes plus the bare essentials install.sh needs
    # (curl, tar, mkdir, etc.). Pulling them from /usr/bin keeps the test
    # portable without depending on the host's Python at all.
    result = _run(
        [],
        sandbox=sandbox,
        tarball=source_tarball,
        extra_env={"PATH": f"{bin_dir}:/usr/bin:/bin"},
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_no_sudo_invocation():
    """Sanity: install.sh must never *invoke* sudo. Mentions in user-facing
    strings (e.g. 'no sudo required') are fine — we only flag command-position
    occurrences (start of line or after a shell separator)."""
    text = INSTALL_SH.read_text()
    sudo_invoke = re.compile(
        r"(?:^|[;&|]|\$\(|`)\s*sudo(?:\s|$)",
        re.MULTILINE,
    )
    matches = sudo_invoke.findall(text)
    assert not matches, f"install.sh must not invoke sudo (matched {len(matches)})"
