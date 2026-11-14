#!/usr/bin/env python3
import re
import shutil
import subprocess
import sys
from pathlib import Path


def dependencies(binary):
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    return re.findall(r"^\s+(.+?) \(compatibility version ", output, re.MULTILINE)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: relocate-cdrdao.py <libexec-directory> <library-directory>")

    libexec = Path(sys.argv[1]).resolve()
    libraries = Path(sys.argv[2]).resolve()
    libraries.mkdir(parents=True, exist_ok=True)
    tools = [libexec / "cdrdao"]
    queue = list(tools)
    bundled = {}
    source_by_name = {}

    while queue:
        binary = queue.pop(0)
        for dependency in dependencies(binary):
            if not dependency.startswith("/opt/homebrew/"):
                continue
            source = Path(dependency).resolve(strict=True)
            target = libraries / source.name
            previous = bundled.get(dependency)
            if previous is not None:
                replacement = previous
            else:
                source_for_name = source_by_name.get(source.name)
                if source_for_name is not None and source_for_name != source:
                    raise SystemExit(f"conflicting bundled library name: {source.name}")
                source_by_name[source.name] = source
                shutil.copy2(source, target)
                replacement = target
                bundled[dependency] = replacement
                queue.append(target)
                subprocess.run(
                    ["install_name_tool", "-id", f"@rpath/{target.name}", str(target)],
                    check=True,
                )

            relative = (
                f"@loader_path/lib/{replacement.name}"
                if binary in tools
                else f"@loader_path/{replacement.name}"
            )
            subprocess.run(
                ["install_name_tool", "-change", dependency, relative, str(binary)],
                check=True,
            )

    for binary in tools:
        unresolved = [
            item
            for item in dependencies(binary)
            if item.startswith("/opt/homebrew/")
        ]
        if unresolved:
            raise SystemExit(f"unrelocated Homebrew dependencies in {binary}: {unresolved}")

    for bundled_file in [*tools, *libraries.glob("*.dylib")]:
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundled_file)], check=True)


if __name__ == "__main__":
    main()
