#!/usr/bin/env python3
import re
import shutil
import subprocess
import sys
from pathlib import Path


HOMEBREW_PREFIXES = ("/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/")


def dependencies(binary):
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    return re.findall(r"^\s+(.+?) \(compatibility version ", output, re.MULTILINE)


def copy_licenses(source, destination):
    if Path("/opt/homebrew") not in source.parents and Path("/usr/local") not in source.parents:
        return
    formula_root = source.parents[1]
    license_files = [
        path
        for pattern in ("LICENSE*", "COPYING*", "COPYRIGHT*")
        for path in formula_root.glob(pattern)
        if path.is_file() and not path.name.startswith("._")
    ]
    if not license_files:
        return
    output = destination / "FFmpeg-Licenses"
    output.mkdir(exist_ok=True)
    for license_file in license_files:
        name = f"{formula_root.name}-{formula_root.parent.name}-{license_file.name}"
        target = output / name
        if not target.exists():
            shutil.copy2(license_file, target)


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: bundle-ffmpeg.py <source-ffmpeg> <app-ffmpeg> <library-directory>")

    source_binary = Path(sys.argv[1]).resolve(strict=True)
    binary = Path(sys.argv[2]).resolve()
    libraries = Path(sys.argv[3]).resolve()
    binary.parent.mkdir(parents=True, exist_ok=True)
    if libraries.exists():
        shutil.rmtree(libraries)
    libraries.mkdir(parents=True, exist_ok=True)
    license_directory = binary.parent / "FFmpeg-Licenses"
    if license_directory.exists():
        shutil.rmtree(license_directory)
    if binary.exists():
        binary.chmod(0o644)
    shutil.copy2(source_binary, binary)
    copy_licenses(source_binary, binary.parent)

    queue = [binary]
    bundled = {}
    source_by_name = {}
    while queue:
        current = queue.pop(0)
        for dependency in dependencies(current):
            if not dependency.startswith(HOMEBREW_PREFIXES):
                continue
            source = Path(dependency).resolve(strict=True)
            copy_licenses(source, binary.parent)
            previous = bundled.get(source)
            if previous is not None:
                replacement = previous
            else:
                source_for_name = source_by_name.get(source.name)
                if source_for_name is not None and source_for_name != source:
                    raise SystemExit(f"conflicting bundled library name: {source.name}")
                source_by_name[source.name] = source
                replacement = libraries / source.name
                if replacement.exists():
                    replacement.chmod(0o644)
                shutil.copy2(source, replacement)
                bundled[source] = replacement
                queue.append(replacement)
                subprocess.run(
                    ["install_name_tool", "-id", f"@loader_path/{replacement.name}", str(replacement)],
                    check=True,
                )

            relative = (
                f"@loader_path/ffmpeg-libs/{replacement.name}"
                if current == binary
                else f"@loader_path/{replacement.name}"
            )
            subprocess.run(
                ["install_name_tool", "-change", dependency, relative, str(current)],
                check=True,
            )

    unresolved = [
        (current, dependency)
        for current in [binary, *libraries.glob("*.dylib")]
        for dependency in dependencies(current)
        if dependency.startswith(HOMEBREW_PREFIXES)
    ]
    if unresolved:
        raise SystemExit(f"unrelocated Homebrew dependencies: {unresolved}")

    for bundled_file in [binary, *libraries.glob("*.dylib")]:
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundled_file)], check=True)


if __name__ == "__main__":
    main()
