#!/usr/bin/env python3
"""Install this status line into a Claude Code configuration directory."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def die(program_name: str, message: str) -> None:
    print(f"{program_name}: {message}", file=sys.stderr)
    raise SystemExit(1)


def program_name(argv: list[str]) -> str:
    if argv:
        return Path(argv[0]).name
    return Path(__file__).name


def absolute_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path.resolve()


def copy_dir(program: str, src: Path, dest: Path) -> None:
    if not src.is_dir():
        die(program, f"missing source directory: {src}")
    if dest.is_absolute() and dest == Path(dest.anchor):
        die(program, f"refusing unsafe destination: {dest}")
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


def find_source_root(script_path: Path, program: str) -> Path:
    for candidate in [script_path.parent, *script_path.parent.parents]:
        if (candidate / "statusline.py").is_file() and (
            candidate / "statusline-zig" / "build.zig"
        ).is_file():
            return candidate

    die(
        program,
        f"could not find project sources by searching upward from {script_path}",
    )
    raise AssertionError("unreachable")


class ProjectSources:
    """Source files discovered relative to this setup script."""

    def __init__(self, script_path: Path, program: str) -> None:
        self.program = program
        self.script_path = script_path.resolve()
        self.root = find_source_root(self.script_path, program)
        self.statusline_py = self.root / "statusline.py"
        self.readme = self.root / "README.md"
        self.license = self.root / "LICENSE"
        self.zig_root = self.root / "statusline-zig"
        self.zig_build = self.zig_root / "build.zig"
        self.zig_src = self.zig_root / "src"
        self.zig_tests = self.zig_root / "tests"

    def validate(self) -> None:
        required_files = [
            self.statusline_py,
            self.readme,
            self.license,
            self.zig_build,
        ]
        for path in required_files:
            if not path.is_file():
                die(
                    self.program,
                    f"missing source file relative to {self.script_path}: {path}",
                )

        required_dirs = [self.zig_src, self.zig_tests]
        for path in required_dirs:
            if not path.is_dir():
                die(
                    self.program,
                    f"missing source directory relative to {self.script_path}: {path}",
                )


class InstallTarget:
    def __init__(
        self,
        claude_dir: Path,
        install_root: Path | None,
        program: str,
    ) -> None:
        self.program = program
        self.claude_dir = claude_dir.expanduser()
        self.install_root = (
            install_root.expanduser()
            if install_root
            else self.claude_dir / "claude-code-prompt"
        )
        self.settings_path = self.claude_dir / "settings.json"

    def validate(self) -> None:
        self.claude_dir = absolute_dir(self.claude_dir)
        self.install_root = (
            absolute_dir(self.install_root)
            if self.install_root.exists()
            else self.install_root.resolve()
        )
        self.settings_path = self.claude_dir / "settings.json"

        if self.claude_dir == Path(self.claude_dir.anchor):
            die(
                self.program,
                f"refusing unsafe Claude config directory: {self.claude_dir}",
            )
        if self.install_root == Path(self.install_root.anchor):
            die(self.program, f"refusing unsafe install root: {self.install_root}")
        if self.install_root == self.claude_dir:
            die(
                self.program,
                "install root must be a subdirectory, not the Claude config directory itself",
            )


def copy_install_files(
    program: str,
    sources: ProjectSources,
    install_root: Path,
) -> None:
    (install_root / "statusline-zig").mkdir(parents=True, exist_ok=True)

    shutil.copy2(sources.statusline_py, install_root / "statusline.py")
    shutil.copy2(sources.readme, install_root / "README.md")
    shutil.copy2(sources.license, install_root / "LICENSE")
    shutil.copy2(
        sources.zig_build,
        install_root / "statusline-zig" / "build.zig",
    )
    copy_dir(program, sources.zig_src, install_root / "statusline-zig" / "src")
    copy_dir(program, sources.zig_tests, install_root / "statusline-zig" / "tests")


def build_zig_statusline(program: str, install_root: Path) -> Path:
    zig_dir = install_root / "statusline-zig"
    try:
        subprocess.run(
            ["zig", "build", "-Doptimize=ReleaseFast"],
            cwd=zig_dir,
            check=True,
        )
    except FileNotFoundError as exc:
        die(program, "missing required command: zig")
        raise AssertionError from exc
    except subprocess.CalledProcessError as exc:
        die(program, f"zig build failed with exit code {exc.returncode}")

    statusline_bin = zig_dir / "zig-out" / "bin" / "statusline"
    if not os.access(statusline_bin, os.X_OK):
        die(program, f"build did not produce executable: {statusline_bin}")
    return statusline_bin.resolve()


def load_settings(program: str, settings_path: Path) -> tuple[dict[str, Any], str]:
    if not settings_path.exists():
        return {}, ""

    old_text = settings_path.read_text()
    if not old_text.strip():
        return {}, old_text

    try:
        data = json.loads(old_text)
    except json.JSONDecodeError as exc:
        die(program, f"{settings_path} is not valid JSON: {exc}")

    if not isinstance(data, dict):
        die(program, f"{settings_path} must contain a JSON object")

    return data, old_text


def write_settings(program: str, settings_path: Path, command: Path) -> None:
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    data, old_text = load_settings(program, settings_path)

    data["statusLine"] = {
        "type": "command",
        "command": str(command),
        "padding": 0,
    }

    new_text = json.dumps(data, indent=2) + "\n"
    if new_text == old_text:
        return

    if old_text:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_path = settings_path.with_name(f"{settings_path.name}.bak.{stamp}")
        backup_path.write_text(old_text)

    tmp_path = settings_path.with_suffix(settings_path.suffix + ".tmp")
    tmp_path.write_text(new_text)
    tmp_path.replace(settings_path)


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_claude_dir = Path(os.environ.get("CLAUDE_DIR", "~/.claude")).expanduser()
    default_install_root = os.environ.get("INSTALL_ROOT")

    parser = argparse.ArgumentParser(
        prog=program_name(argv),
        description=(
            "Copy this statusline project into a Claude Code config directory, "
            "build the Zig binary, and configure statusLine.command."
        ),
    )
    parser.add_argument(
        "--claude-dir",
        type=Path,
        default=default_claude_dir,
        help="Claude Code config directory; default: %(default)s",
    )
    parser.add_argument(
        "--install-root",
        type=Path,
        default=Path(default_install_root).expanduser()
        if default_install_root
        else None,
        help="Managed install directory; default: CLAUDE_DIR/claude-code-prompt",
    )
    return parser.parse_args(argv[1:])


def run(argv: list[str], script_path: Path) -> None:
    program = program_name(argv)
    args = parse_args(argv)
    sources = ProjectSources(script_path, program)
    target = InstallTarget(args.claude_dir, args.install_root, program)

    sources.validate()
    target.validate()
    copy_install_files(program, sources, target.install_root)
    statusline_bin = build_zig_statusline(program, target.install_root)
    write_settings(program, target.settings_path, statusline_bin)

    print(f"Installed Claude Code status line to {target.install_root}")
    print(f"Configured {target.settings_path}")
    print(f"statusLine.command = {statusline_bin}")


if __name__ == "__main__":
    run(sys.argv, Path(__file__))
