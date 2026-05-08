"""Verify the legacy → XDG migration in lib/clawkey-runtime.sh.

Drives the migration entirely with shell so we can isolate $HOME and CLAWKEY_DIR
on a temp dir without touching the user's real config.
"""

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RUNTIME_LIB = PROJECT_ROOT / "lib" / "clawkey-runtime.sh"


def _run_migration(home: Path, clawkey_dir: Path) -> subprocess.CompletedProcess:
    """Source the runtime lib in a hermetic env and run the migration helpers."""
    script = textwrap.dedent(f"""\
        set -euo pipefail
        export HOME={home!s}
        export CLAWKEY_DIR={clawkey_dir!s}
        unset XDG_CONFIG_HOME XDG_STATE_HOME
        unset CLAWKEY_CONFIG_DIR CLAWKEY_STATE_DIR CLAWKEY_ENV_FILE CLAWKEY_MODEL_CONFIG CLAWKEY_PROXY_LOG
        . {RUNTIME_LIB!s}
        clawkey_migrate_legacy_config
        clawkey_seed_model_config
    """)
    return subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, check=True
    )


def _scaffold_clawkey_dir(dest: Path):
    """Build a minimal CLAWKEY_DIR with just the in-tree litellm_config.yaml template."""
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy(PROJECT_ROOT / "litellm_config.yaml", dest / "litellm_config.yaml")


def test_migration_moves_legacy_env(tmp_path):
    home = tmp_path / "home"
    clawkey_dir = tmp_path / "src"
    home.mkdir()
    _scaffold_clawkey_dir(clawkey_dir)
    legacy_env = clawkey_dir / ".env"
    legacy_env.write_text("AI_SANDBOX_KEY=test-key\nLITELLM_MASTER_KEY=sk-clawkey-abc\n")

    _run_migration(home, clawkey_dir)

    assert not legacy_env.exists(), "legacy .env should have been moved"
    new_env = home / ".config" / "clawkey" / ".env"
    assert new_env.exists(), "XDG .env should exist after migration"
    assert "AI_SANDBOX_KEY=test-key" in new_env.read_text()


def test_migration_seeds_model_config_from_template(tmp_path):
    home = tmp_path / "home"
    clawkey_dir = tmp_path / "src"
    home.mkdir()
    _scaffold_clawkey_dir(clawkey_dir)

    _run_migration(home, clawkey_dir)

    seeded = home / ".config" / "clawkey" / "litellm_config.yaml"
    assert seeded.exists(), "XDG litellm_config.yaml must be seeded from template"
    # Template ships with model_list: [].
    assert "model_list:" in seeded.read_text()


def test_migration_is_idempotent(tmp_path):
    home = tmp_path / "home"
    clawkey_dir = tmp_path / "src"
    home.mkdir()
    _scaffold_clawkey_dir(clawkey_dir)
    (clawkey_dir / ".env").write_text("AI_SANDBOX_KEY=x\n")

    _run_migration(home, clawkey_dir)
    # Second run must not error and must not re-create the legacy file.
    _run_migration(home, clawkey_dir)

    assert not (clawkey_dir / ".env").exists()
    assert (home / ".config" / "clawkey" / ".env").exists()


def test_migration_preserves_existing_xdg_files(tmp_path):
    """If XDG already has a .env, migration must not overwrite it from a legacy file."""
    home = tmp_path / "home"
    clawkey_dir = tmp_path / "src"
    home.mkdir()
    _scaffold_clawkey_dir(clawkey_dir)
    (clawkey_dir / ".env").write_text("AI_SANDBOX_KEY=legacy\n")
    xdg_env = home / ".config" / "clawkey" / ".env"
    xdg_env.parent.mkdir(parents=True)
    xdg_env.write_text("AI_SANDBOX_KEY=already-set\n")

    _run_migration(home, clawkey_dir)

    # XDG file untouched, legacy file still in place (we only migrate when XDG is absent).
    assert "already-set" in xdg_env.read_text()
    assert (clawkey_dir / ".env").exists()


def test_migration_moves_legacy_proxy_log(tmp_path):
    home = tmp_path / "home"
    clawkey_dir = tmp_path / "src"
    home.mkdir()
    _scaffold_clawkey_dir(clawkey_dir)
    legacy_log = home / ".clawkey" / "proxy.log"
    legacy_log.parent.mkdir()
    legacy_log.write_text("hello from old log\n")

    _run_migration(home, clawkey_dir)

    new_log = home / ".local" / "state" / "clawkey" / "proxy.log"
    assert new_log.exists(), "proxy log should be migrated to XDG state dir"
    assert "hello from old log" in new_log.read_text()
    assert not legacy_log.exists(), "legacy log should have been moved"
