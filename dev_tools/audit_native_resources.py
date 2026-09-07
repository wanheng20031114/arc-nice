"""Load all tracked Godot scripts/scenes/resources, without instantiating them."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def collect(repository: Path) -> dict[Path, list[Path]]:
    tracked = subprocess.check_output(
        ["git", "ls-files", "--cached", "-z"], cwd=repository
    ).decode("utf-8").split("\0")
    projects: dict[Path, list[Path]] = {}
    for name in sorted(set(tracked)):
        path = repository / name
        if path.suffix not in {".gd", ".tscn", ".tres"} or not path.is_file():
            continue
        project = next(parent for parent in path.parents if (parent / "project.godot").is_file())
        projects.setdefault(project, []).append(path)
    return projects


def classify_log(text: str) -> list[dict[str, str]]:
    issues = []
    current = "<startup>"
    for line in text.splitlines():
        if line.startswith("NATIVE_RESOURCE_BEGIN "):
            current = line.removeprefix("NATIVE_RESOURCE_BEGIN ")
        elif line.startswith("NATIVE_RESOURCE_AUDIT "):
            current = "<shutdown>"
        elif "SCRIPT ERROR:" in line or "ERROR:" in line or "WARNING:" in line:
            category = "script" if "SCRIPT ERROR:" in line else "warning" if "WARNING:" in line else "native"
            issues.append({"phase_or_resource": current, "category": category, "message": line.strip()})
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=Path("C:/Program Files/Godot/Godot.exe"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest-only", action="store_true")
    parser.add_argument("--timeout", type=float, default=180.0, help="Per-project timeout in seconds")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    owner = uuid.uuid4().hex
    source = Path(__file__).with_name("resource_native_load_probe.gd")
    projects = collect(repository)
    metadata = {
        "owner": owner,
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository).decode().strip(),
        "probe_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "projects": [],
        "scope": "Git tracked working files, native synchronous load only; no scene/script instantiation",
    }
    (output / "workspace.patch").write_bytes(subprocess.check_output(["git", "diff", "HEAD", "--"], cwd=repository))
    status = 0
    for index, (project, paths) in enumerate(projects.items()):
        folder = output / f"project_{index}"
        folder.mkdir(exist_ok=True)
        manifest = ["res://" + path.relative_to(project).as_posix() for path in paths]
        write_json(folder / "manifest.json", manifest)
        write_json(folder / "source_hashes.json", {
            path.relative_to(repository).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths
        })
        record = {
            "root": str(project), "counts": dict(Counter(path.suffix for path in paths)),
            "manifest": str(folder / "manifest.json"), "items": len(paths),
        }
        metadata["projects"].append(record)
        write_json(output / "metadata.json", metadata)
        if args.manifest_only:
            print(json.dumps(record, ensure_ascii=False), flush=True)
            continue
        command = [str(args.godot), "--headless", "--path", str(project),
                   "--script", str(source), "--", f"--manifest={folder / 'manifest.json'}",
                   f"--result={folder / 'results.json'}", f"--native-resource-audit-owner={owner}"]
        record["command"] = command
        started = time.monotonic()
        process = None
        try:
            with (folder / "godot.log").open("wb") as log:
                process = subprocess.Popen(command, cwd=repository, stdout=log, stderr=subprocess.STDOUT,
                                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                record["pid"] = process.pid
                write_json(output / "metadata.json", metadata)
                try:
                    record["exit_code"] = process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    record["timeout"] = True
                    process.kill()
                    record["exit_code"] = process.wait(timeout=10)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            record["elapsed_seconds"] = round(time.monotonic() - started, 3)
            record["owned_process_exited"] = process is not None and process.poll() is not None
        issues = classify_log((folder / "godot.log").read_text(encoding="utf-8", errors="replace"))
        record["issues"] = issues
        results_path = folder / "results.json"
        results = json.loads(results_path.read_text(encoding="utf-8")) if results_path.exists() else {}
        record["completed_items"] = len(results.get("results", []))
        record["null_resources"] = results.get("null_resources")
        record["strict_pass"] = (
            record.get("exit_code") == 0 and not issues
            and record["completed_items"] == len(paths) and record["null_resources"] == 0
        )
        if not record["strict_pass"]:
            status = 1
        write_json(output / "metadata.json", metadata)
        print(json.dumps(record, ensure_ascii=False), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
