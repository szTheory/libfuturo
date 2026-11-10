#!/usr/bin/env python3
"""Run Apple's Clang Static Analyzer against CMake compile databases.

This is an opt-in advisory tool. Analyzer findings are printed but do not make
the command fail; malformed databases and failed compiler invocations do.
Only translation units under this checkout and outside each CMake build tree
are analyzed, so dependency copies and generated files inside build trees are
excluded.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CompileCommand:
    database: Path
    directory: Path
    source: Path
    compiler: str
    arguments: tuple[str, ...]

    @property
    def key(self) -> tuple[str, str, tuple[str, ...]]:
        return (str(self.directory), self.compiler, self.arguments)


def parse_command(entry: dict, database: Path) -> tuple[Path, list[str]]:
    directory_value = entry.get("directory")
    source_value = entry.get("file")
    if not isinstance(directory_value, str) or not isinstance(source_value, str):
        raise ValueError(f"{database}: each entry needs string directory and file fields")

    directory = Path(directory_value).resolve()
    raw_arguments = entry.get("arguments")
    if isinstance(raw_arguments, list) and all(isinstance(arg, str) for arg in raw_arguments):
        arguments = raw_arguments
    elif isinstance(entry.get("command"), str):
        arguments = shlex.split(entry["command"])
    else:
        raise ValueError(f"{database}: entry for {source_value} has no usable command or arguments")

    if not arguments:
        raise ValueError(f"{database}: entry for {source_value} has an empty compiler command")
    return directory, [*arguments]


def analyzer_arguments(arguments: list[str]) -> list[str]:
    """Drop compile outputs and dependency side effects before adding --analyze."""
    result: list[str] = []
    skip_next = False
    value_options = {"-o", "-MF", "-MT", "-MQ", "-MJ", "-serialize-diagnostics"}
    output_prefixes = ("-MF", "-MT", "-MQ", "-MJ")
    compile_only = {"-c", "-MD", "-MMD", "-MP", "-M", "-MM"}

    for argument in arguments:
        if skip_next:
            skip_next = False
            continue
        if argument in value_options:
            skip_next = True
            continue
        if argument in compile_only:
            continue
        if any(argument.startswith(prefix) and argument != prefix for prefix in output_prefixes):
            continue
        result.append(argument)
    return result


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def load_commands(database: Path, source_root: Path) -> tuple[list[CompileCommand], int]:
    try:
        payload = json.loads(database.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read compilation database {database}: {error}") from error
    if not isinstance(payload, list):
        raise ValueError(f"{database}: expected a JSON array")

    build_root = database.parent.resolve()
    cache_file = build_root / "CMakeCache.txt"
    if not cache_file.is_file():
        raise ValueError(f"{database}: expected adjacent CMakeCache.txt to identify the build tree")
    cache_text = cache_file.read_text(encoding="utf-8", errors="replace")
    home_match = re.search(r"^CMAKE_HOME_DIRECTORY:INTERNAL=(.+)$", cache_text, re.MULTILINE)
    home_directory = Path(home_match.group(1)).resolve() if home_match else None
    if home_directory is None or not is_within(home_directory, source_root):
        found = home_match.group(1) if home_match else "missing"
        raise ValueError(
            f"{database}: CMake source directory {found!r} does not match {source_root}"
        )

    commands: list[CompileCommand] = []
    skipped = 0
    for index, entry in enumerate(payload):
        if not isinstance(entry, dict):
            raise ValueError(f"{database}: entry {index} is not an object")
        directory, arguments = parse_command(entry, database)
        source = Path(entry["file"])
        if not source.is_absolute():
            source = directory / source
        source = source.resolve()
        if not is_within(source, source_root) or is_within(source, build_root):
            skipped += 1
            continue
        if not source.is_file():
            raise ValueError(f"{database}: first-party source does not exist: {source}")

        compiler = shutil.which(arguments[0])
        if compiler is None:
            raise ValueError(f"{database}: compiler is unavailable: {arguments[0]}")
        clean_arguments = analyzer_arguments(arguments[1:])
        commands.append(
            CompileCommand(
                database=database,
                directory=directory,
                source=source,
                compiler=compiler,
                arguments=tuple(clean_arguments),
            )
        )
    return commands, skipped


def verify_apple_clang(compiler: str, checked: set[str]) -> None:
    if compiler in checked:
        return
    try:
        result = subprocess.run(
            [compiler, "--version"], text=True, capture_output=True, check=False
        )
    except OSError as error:
        raise ValueError(f"cannot run compiler {compiler}: {error}") from error
    version = (result.stdout + result.stderr).splitlines()
    first_line = version[0] if version else "no version output"
    if result.returncode != 0 or "Apple clang" not in first_line:
        raise ValueError(f"expected Apple Clang, got {compiler}: {first_line}")
    print(f"Compiler: {compiler} ({first_line})")
    checked.add(compiler)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run advisory Apple Clang static analysis from CMake compilation databases."
    )
    parser.add_argument(
        "compile_commands",
        nargs="+",
        type=Path,
        metavar="COMPILE_COMMANDS_JSON",
        help="one or more CMake compilation databases",
    )
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="checkout root used to select first-party sources (default: this checkout)",
    )
    args = parser.parse_args()

    source_root = args.source_root.resolve()
    if not source_root.is_dir():
        parser.error(f"source root does not exist: {source_root}")

    started_at = time.perf_counter()
    all_commands: list[CompileCommand] = []
    skipped_records = 0
    try:
        for raw_database in args.compile_commands:
            database = raw_database.resolve(strict=True)
            commands, skipped = load_commands(database, source_root)
            print(
                f"Database: {database} ({len(commands)} first-party compile records, "
                f"{skipped} dependency/build-tree records skipped)"
            )
            all_commands.extend(commands)
            skipped_records += skipped
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    unique: list[CompileCommand] = []
    seen: set[tuple[str, str, tuple[str, ...]]] = set()
    for command in all_commands:
        if command.key in seen:
            continue
        seen.add(command.key)
        unique.append(command)
    if not unique:
        print("error: no first-party compile commands were found", file=sys.stderr)
        return 2

    checked_compilers: set[str] = set()
    for command in unique:
        try:
            verify_apple_clang(command.compiler, checked_compilers)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2

    warning_headers = 0
    failures = 0
    for number, command in enumerate(unique, start=1):
        invocation = [
            command.compiler,
            *command.arguments,
            "--analyze",
            "-Xanalyzer",
            "-analyzer-output=text",
            "-o",
            os.devnull,
        ]
        try:
            result = subprocess.run(
                invocation,
                cwd=command.directory,
                text=True,
                capture_output=True,
                check=False,
            )
        except OSError as error:
            print(f"error: cannot analyze {command.source}: {error}", file=sys.stderr)
            failures += 1
            continue

        output = result.stdout + result.stderr
        warning_headers += len(re.findall(r"\bwarning:", output))
        if output:
            print(f"[{number}/{len(unique)}] {command.source.relative_to(source_root)}")
            print(output, end="" if output.endswith("\n") else "\n")
        if result.returncode != 0:
            failures += 1
            print(
                f"error: analyzer exited {result.returncode} for "
                f"{command.source.relative_to(source_root)}",
                file=sys.stderr,
            )

    elapsed = time.perf_counter() - started_at
    unique_sources = len({command.source for command in unique})
    print(
        "Analyzer summary: "
        f"compile_records={len(all_commands)} "
        f"unique_invocations={len(unique)} "
        f"unique_sources={unique_sources} "
        f"dependency_or_build_records_skipped={skipped_records} "
        f"diagnostic_headers={warning_headers} "
        f"failed_invocations={failures} "
        f"elapsed_seconds={elapsed:.2f}"
    )
    print("Advisory policy: findings do not fail this command; invocation failures do.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
