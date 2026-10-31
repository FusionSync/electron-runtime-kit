#!/usr/bin/env python3
"""Audit release archives for architecture, GLIBC and native-file requirements."""
from __future__ import annotations
import argparse
import json
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path

ARCH_MACHINE = {
    "x64": "Advanced Micro Devices X86-64",
    "arm64": "AArch64",
    "loong64": "LoongArch",
}
NAME_RE = re.compile(r"^(node-pty|sharp|koffi|landlock-run|ripgrep|sherpa-onnx-node)-(.+)-linux-(x64|arm64|loong64)\.tar\.gz$")


def readelf(option: str, path: Path) -> str:
    return subprocess.check_output(["readelf", "--wide", option, str(path)], text=True, stderr=subprocess.STDOUT)


def version_key(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def audit_elf(path: Path) -> dict:
    header = readelf("--file-header", path)
    dynamic = readelf("--dynamic", path)
    versions = set(re.findall(r"Name: GLIBC_([0-9.]+)\b", readelf("--version-info", path)))
    glibc = max(versions, key=version_key) if versions else None
    return {
        "path": str(path),
        "machine": re.search(r"^\s*Machine:\s*(.+)$", header, re.MULTILINE).group(1),
        "glibc_max": glibc,
        "needed": re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic),
        "rpath": re.findall(r"\(RPATH\).*?\[([^]]*)\]", dynamic),
        "runpath": re.findall(r"\(RUNPATH\).*?\[([^]]*)\]", dynamic),
    }


def required_paths(package: str, arch: str) -> list[str]:
    sharp_arch = {"x64": "x64", "arm64": "arm64v8", "loong64": "loong64"}[arch]
    if package == "node-pty":
        return ["node-pty/build/Release/pty.node", "node-pty/build/Release/spawn-helper"]
    if package == "sharp":
        return [f"sharp/build/Release/sharp-linux-{sharp_arch}.node", "sharp/vendor/8.14.5/"]
    if package == "koffi":
        return [
            f"koffi/build/koffi/linux_{arch}/koffi.node",
            f"@koromix/koffi-linux-{arch}/linux_{arch}/koffi.node",
        ]
    if package == "landlock-run":
        return [
            "@deepseek-ai/node-addon-landlock-run/package.json",
            f"@deepseek-ai/node-addon-landlock-run-linux-{arch}/bin/landlock-run",
        ]
    if package == "ripgrep":
        return [
            "@vscode/ripgrep/package.json",
            f"@vscode/ripgrep-linux-{arch}/bin/rg",
        ]
    return [f"sherpa-onnx-linux-{arch}/sherpa-onnx.node", f"sherpa-onnx-linux-{arch}/libonnxruntime.so"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release_dir", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    archives = sorted(args.release_dir.glob("*.tar.gz"))
    if not archives:
        raise SystemExit(f"no .tar.gz assets in {args.release_dir}")
    report = {"glibc_limit": "2.28", "passed": True, "archives": []}
    for archive in archives:
        match = NAME_RE.match(archive.name)
        if not match:
            raise SystemExit(f"unrecognized asset name: {archive.name}")
        package, version, arch = match.groups()
        with tempfile.TemporaryDirectory(prefix="native-audit-") as temp:
            root = Path(temp)
            with tarfile.open(archive, "r:gz") as stream:
                stream.extractall(root)
            files = [path for path in root.rglob("*") if path.is_file()]
            names = [str(path.relative_to(root)) for path in files]
            missing = [item for item in required_paths(package, arch)
                       if not any(name == item or (item.endswith("/") and name.startswith(item)) for name in names)]
            elfs = []
            for path in files:
                try:
                    if path.read_bytes()[:4] == b"\x7fELF":
                        elfs.append(audit_elf(path))
                except OSError:
                    pass
            errors = []
            expected_machine = ARCH_MACHINE[arch]
            for item in elfs:
                if expected_machine not in item["machine"]:
                    errors.append(f"{item['path']}: expected {expected_machine}, got {item['machine']}")
                if item["glibc_max"] and version_key(item["glibc_max"]) > (2, 28):
                    errors.append(f"{item['path']}: GLIBC_{item['glibc_max']} exceeds 2.28")
                if item["needed"] and package in {"sharp", "sherpa-onnx-node"}:
                    paths = item["rpath"] + item["runpath"]
                    if "$ORIGIN" not in paths:
                        errors.append(f"{item['path']}: missing $ORIGIN RPATH/RUNPATH")
            if missing:
                errors.append("missing required paths: " + ", ".join(missing))
            entry = {"asset": archive.name, "package": package, "version": version, "arch": arch,
                     "sha256": __import__("hashlib").sha256(archive.read_bytes()).hexdigest(),
                     "files": elfs, "errors": errors, "passed": not errors}
            report["archives"].append(entry)
            report["passed"] = report["passed"] and not errors
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.json:
        args.json.write_text(text)
    print(text, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
