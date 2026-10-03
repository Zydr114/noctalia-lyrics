#!/usr/bin/env python3
"""Overlay the new backend on an installed plugin without replacing its UI."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ID = "h465855hgg/lyrics"
BACKEND_FILES = ("lyrics_service.luau", "lyric_sources.py", "music_sources.py")


def install(base, destination, backup_root, dry_run=True):
    base, destination = Path(base).resolve(), Path(destination).resolve()
    manifest = tomllib.loads((base / "plugin.toml").read_text())
    if manifest.get("id") != PLUGIN_ID:
        raise ValueError("base directory is not the Lyrics plugin")
    for name in BACKEND_FILES:
        if not (ROOT / name).is_file():
            raise ValueError("missing backend file: " + name)
    if destination.exists():
        existing = tomllib.loads((destination / "plugin.toml").read_text())
        if existing.get("id") != PLUGIN_ID:
            raise ValueError("destination belongs to a different plugin")
    if base == destination:
        raise ValueError("base and destination must differ; use the materialized community copy as base")
    print("Base:", base, "(version " + manifest.get("version", "unknown") + ")")
    print("Local override:", destination)
    if dry_run:
        print("Dry run: would copy the installed plugin and replace only", ", ".join(BACKEND_FILES))
        return None

    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".lyrics-backend-", dir=destination.parent))
    backup = None
    try:
        shutil.copytree(base, stage, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".cache", "__pycache__", ".git"))
        stage.chmod(stage.stat().st_mode | 0o700)
        for directory in stage.rglob("*"):
            if directory.is_dir():
                directory.chmod(directory.stat().st_mode | 0o700)
        for name in BACKEND_FILES:
            (stage / name).unlink(missing_ok=True)
            shutil.copy2(ROOT / name, stage / name)
        # In 1.5.x display_mode belongs to each widget, so the service cannot
        # read it. Keep the older global track-only behaviour only when declared.
        if not any(setting.get("key") == "display_mode" for setting in manifest.get("setting", [])):
            service_path = stage / "lyrics_service.luau"
            service = service_path.read_text().replace(
                'noctalia.getConfig("display_mode") or "toggle"', '"toggle"')
            service_path.write_text(service)
        manifest_path = stage / "plugin.toml"
        if "timeout" not in manifest.get("dependencies", []):
            manifest_path.chmod(manifest_path.stat().st_mode | 0o600)
            dependencies = [*manifest.get("dependencies", []), "timeout"]
            updated, count = re.subn(r"^dependencies\s*=\s*\[[^\n]*\]", "dependencies = " + json.dumps(dependencies),
                                     manifest_path.read_text(), count=1, flags=re.M)
            if count != 1:
                raise ValueError("cannot update dependencies in the installed manifest")
            manifest_path.write_text(updated)
        (stage / "BACKEND-OVERLAY.json").write_text(json.dumps({
            "base_version": manifest.get("version"), "base_directory": str(base),
            "backend": "netease-qq-recovery", "files": BACKEND_FILES,
        }, indent=2) + "\n")
        if destination.exists():
            backup_root = Path(backup_root)
            backup_root.mkdir(parents=True, exist_ok=True)
            backup = backup_root / datetime.now().strftime("lyrics-%Y%m%d-%H%M%S-%f")
            shutil.copytree(destination, backup, ignore=shutil.ignore_patterns(".cache", "__pycache__"))
            old = stage.parent / (stage.name + "-old")
            destination.rename(old)
            try:
                stage.rename(destination)
            except OSError:
                old.rename(destination)
                raise
            shutil.rmtree(old)
        else:
            stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    if backup:
        print("Previous local override backup:", backup)
    print("Backend copy prepared. Reload Noctalia and restart the Lyrics plugin if this is your local plugin directory.")
    return backup


def main():
    state = Path(os.environ.get("NOCTALIA_STATE_HOME") or Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "noctalia")
    data = Path(os.environ.get("NOCTALIA_DATA_HOME") or Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "noctalia")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=state / "plugins/materialized/community/lyrics")
    parser.add_argument("--destination", type=Path, default=data / "plugins/lyrics")
    parser.add_argument("--backup-root", type=Path, default=state / "lyrics-backend-backups")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--install", action="store_true", help="create the local override")
    mode.add_argument("--dry-run", action="store_true", help="inspect paths without writing (the default)")
    args = parser.parse_args()
    try:
        install(args.base, args.destination, args.backup_root, dry_run=not args.install)
    except (OSError, ValueError) as error:
        parser.exit(1, "Installation failed: " + str(error) + "\n")


if __name__ == "__main__":
    main()
