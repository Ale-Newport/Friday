#!/usr/bin/env python3
"""Writes the licence of every Python distribution installed in the sidecar's environment (the ones PyInstaller can
bundle) to one Markdown file: name, version, declared licence and the full text of the licence files it ships.

    cd Sidecar && uv run python ../Scripts/collect-licenses.py OUT.md
"""

import sys
from importlib import metadata
from pathlib import Path

SKIP = {"pyinstaller", "pyinstaller-hooks-contrib", "pytest", "pytest-asyncio", "ruff", "pluggy", "iniconfig", "altgraph",
        "macholib", "packaging", "setuptools"}  # build and test tools: not shipped in the app


def licence_of(dist: metadata.Distribution) -> str:
    meta = dist.metadata
    expression = meta.get("License-Expression")
    if expression:
        return expression
    classifiers = [c.split(" :: ")[-1] for c in meta.get_all("Classifier") or [] if c.startswith("License ::")]
    if classifiers:
        return ", ".join(classifiers)
    text = (meta.get("License") or "").strip()
    return text.splitlines()[0][:120] if text else "see licence file"


def licence_files(dist: metadata.Distribution) -> list[tuple[str, str]]:
    found = []
    for file in dist.files or []:
        name = file.name.lower()
        if any(name.startswith(prefix) for prefix in ("license", "licence", "copying", "notice", "authors")):
            path = Path(file.locate())
            if path.is_file() and path.stat().st_size < 200_000:
                found.append((str(file), path.read_text(errors="replace")))
    return found


def main() -> None:
    out = Path(sys.argv[1])
    dists = sorted({d.metadata["Name"].lower(): d for d in metadata.distributions()}.items())
    lines = ["# Python components in the Friday sidecar", "",
             "The browser agent (Contents/Resources/backend) is a PyInstaller bundle of these packages.", ""]
    for name, dist in dists:
        if name in SKIP or name == "friday-sidecar":
            continue
        lines += [f"## {dist.metadata['Name']} {dist.version}", "", f"Licence: {licence_of(dist)}", ""]
        for path, text in licence_files(dist):
            lines += [f"<details><summary>{path}</summary>", "", "```", text.strip(), "```", "", "</details>", ""]
    out.write_text("\n".join(lines))
    print(f"wrote {out} ({len(dists)} distributions)")


if __name__ == "__main__":
    main()
