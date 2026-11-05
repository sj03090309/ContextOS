#!/usr/bin/env python3
"""Validate non-installing package output and publish newly built artifacts."""
import argparse
import os
from pathlib import Path


def validate_output(path):
    output = Path(path).absolute()
    if output.is_symlink():
        raise ValueError("Output directory cannot be a symlink.")
    output = output.resolve()
    installed_roots = [Path("/Applications"), Path("/System/Applications"), Path.home() / "Applications"]
    if any(output == root.resolve() or root.resolve() in output.parents for root in installed_roots):
        raise ValueError("Packaging cannot write to an Applications directory; use a separate build output.")
    if output == Path("/") or output == Path.home().resolve() or any(p.suffix.lower() == ".app" for p in [output, *output.parents]):
        raise ValueError("Choose a separate build directory outside an app bundle or home root.")
    if output.exists() and not output.is_dir():
        raise ValueError("Output must be a directory.")
    app = output / "ContextOS.app"
    if app.exists() or app.is_symlink():
        raise ValueError("Refusing to overwrite an existing output app; choose a new output directory.")
    return output


def publish(stage, output, names):
    """Caller holds the output lock. Roll back every move if publication fails."""
    output = validate_output(output)
    stage = Path(stage).resolve()
    if stage.parent != output or not stage.name.startswith(".package-") or not stage.is_dir():
        raise ValueError("Package stage must be a private directory directly inside the output.")
    if not names or len(names) != len(set(names)) or any(Path(name).name != name or name in (".", "..") for name in names):
        raise ValueError("Invalid package artifact names.")
    for name in names:
        source, target = stage / name, output / name
        if source.is_symlink() or not source.exists() or target.exists() or target.is_symlink():
            raise ValueError("Refusing to replace or publish an invalid artifact: " + name)
    moved = []
    try:
        # The app is passed last: it becomes visible only with its archive and
        # checksum already in place. No prior artifacts are replaced.
        for name in names:
            source, target = stage / name, output / name
            if target.exists() or target.is_symlink():
                raise ValueError("Output changed during packaging: " + name)
            os.rename(source, target)
            moved.append(name)
    except BaseException:
        for name in reversed(moved):
            os.rename(output / name, stage / name)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="operation", required=True)
    check = subcommands.add_parser("check")
    check.add_argument("output")
    commit = subcommands.add_parser("publish")
    commit.add_argument("output")
    commit.add_argument("stage")
    commit.add_argument("names", nargs="+")
    args = parser.parse_args()
    if args.operation == "check":
        print(validate_output(args.output))
    else:
        publish(args.stage, args.output, args.names)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit("Packaging stopped: " + str(error))
