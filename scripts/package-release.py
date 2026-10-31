#!/usr/bin/env python3
"""Create deterministic archives with the directory layout consumed by Electron."""
from __future__ import annotations
import argparse
import gzip
import json
import shutil
import tarfile
import tempfile
from pathlib import Path


def parse_spec(value: str) -> tuple[str, list[str]]:
    try:
        name, paths = value.split("=", 1)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("spec must be NAME=PATH[,PATH...]") from exc
    if not name or not paths:
        raise argparse.ArgumentTypeError("spec must be NAME=PATH[,PATH...]")
    return name, [item for item in paths.split(",") if item]


def copy_tree(source: Path, destination: Path) -> None:
    if not source.exists() and not source.is_symlink():
        raise FileNotFoundError(source)
    if source.is_dir():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, destination, symlinks=True)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination, follow_symlinks=False)


def add_deterministic(archive: tarfile.TarFile, path: Path, root: Path) -> None:
    relative = path.relative_to(root)
    info = archive.gettarinfo(str(path), arcname=str(relative))
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    if path.is_file() and not path.is_symlink():
        with path.open("rb") as stream:
            archive.addfile(info, stream)
    else:
        archive.addfile(info)
    if path.is_dir() and not path.is_symlink():
        for child in sorted(path.iterdir()):
            add_deterministic(archive, child, root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=("x64", "arm64", "loong64"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--modules", type=Path, required=True)
    parser.add_argument("--version", type=Path, default=Path("package.json"))
    parser.add_argument("--spec", action="append", type=parse_spec, required=True,
                        help="archive name=relative paths in --modules")
    args = parser.parse_args()
    versions = json.loads(args.version.read_text())
    package_versions = {
        "node-pty": versions["nativeDependencies"]["node-pty"],
        "sharp": versions["nativeDependencies"]["sharp"],
        "koffi": versions["nativeDependencies"]["koffi"],
        "landlock-run": versions["nativeDependencies"]["@deepseek-ai/node-addon-landlock-run"],
        "ripgrep": versions["nativeDependencies"]["@vscode/ripgrep"],
        "sherpa-onnx-node": versions["nativeDependencies"]["sherpa-onnx-node"],
    }
    args.output.mkdir(parents=True, exist_ok=True)
    modules = args.modules.resolve(strict=True)
    for name, paths in args.spec:
        if name not in package_versions:
            raise SystemExit(f"unknown package: {name}")
        with tempfile.TemporaryDirectory(prefix=f"native-{name}-") as temporary:
            payload = Path(temporary) / "payload"
            payload.mkdir()
            for relative in paths:
                copy_tree(modules / relative, payload / relative)
            archive_path = args.output / f"{name}-{package_versions[name]}-linux-{args.arch}.tar.gz"
            if archive_path.exists():
                archive_path.unlink()
            with archive_path.open("wb") as output:
                with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w") as archive:
                        for child in sorted(payload.iterdir()):
                            add_deterministic(archive, child, payload)
            print(archive_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
