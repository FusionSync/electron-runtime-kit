#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

NAME_RE = re.compile(r"^(node-pty|sharp|koffi|landlock-run|ripgrep|sherpa-onnx-node)-(.+)-linux-(x64|arm64|loong64)\.tar\.gz$")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("release_dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--release", help="release name; defaults to the pinned Electron and GLIBC versions")
    args = parser.parse_args()
    package_json = json.loads((Path(__file__).resolve().parents[1] / "package.json").read_text())
    release_name = args.release or (
        f"electron-v{package_json['consumer']['electron']}-glibc-{package_json['target']['glibc_max']}"
    )
    entries = []
    for asset in sorted(args.release_dir.glob("*.tar.gz")):
        match = NAME_RE.match(asset.name)
        if not match:
            raise SystemExit(f"unrecognized asset name: {asset.name}")
        package, version, arch = match.groups()
        entries.append({"package": package, "version": version, "arch": arch,
                        "asset": asset.name,
                        "sha256": hashlib.sha256(asset.read_bytes()).hexdigest()})
    manifest = {"schema_version": 1, "release": release_name,
                "electron": package_json["consumer"]["electron"],
                "glibc_max": package_json["target"]["glibc_max"],
                "build_host": package_json["buildHost"],
                "architectures": package_json["target"]["architectures"],
                "toolchain_release": package_json["toolchain"]["url"],
                "runtime_source": package_json["runtimeSource"]["url"],
                "consumer": package_json["consumer"]["product"], "packages": entries}
    output = args.output or args.release_dir / "manifest.json"
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(output)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
