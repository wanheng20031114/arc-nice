"""Check literal Godot dependencies, respecting nested projects' res:// roots."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess


def audit(repository: Path) -> dict:
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=repository,
    ).decode("utf-8").split("\0")
    counts: dict[str, int] = {}
    missing: list[dict[str, str]] = []
    references = 0
    for relative in sorted(set(paths)):
        path = repository / relative
        if path.suffix not in {".gd", ".tscn", ".tres"} and path.name != "project.godot":
            continue
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8-sig")
        project = next(
            ancestor for ancestor in path.parents
            if (ancestor / "project.godot").is_file()
        )
        counts[path.suffix] = counts.get(path.suffix, 0) + 1
        if path.suffix in {".tscn", ".tres"}:
            dependencies = re.findall(r'\[ext_resource[^\n]+path="(res://[^"]+)"', source)
        elif path.suffix == ".gd":
            dependencies = re.findall(
                r'(?:preload|load)\s*\(\s*"(res://[^"]+)"\s*\)', source
            )
        else:
            dependencies = re.findall(r'^\w+="\*?(res://[^"]+)"', source, re.MULTILINE)
        for dependency in dependencies:
            references += 1
            if not (project / dependency.removeprefix("res://")).exists():
                missing.append({"file": relative, "dependency": dependency})
    return {"files": counts, "literal_dependency_references": references, "missing": missing}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = audit(Path(__file__).resolve().parents[1])
    serialized = json.dumps(result, ensure_ascii=False, indent=2)
    print(serialized)
    if args.output:
        args.output.write_text(serialized + "\n", encoding="utf-8")
    raise SystemExit(1 if result["missing"] else 0)
