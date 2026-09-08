"""Build an isolated, explicit Git revision for the same density fixture.

Production text is materialized from Git; unchanged binary assets are hardlinked.
Only imported assets/cache are shared. Never run the editor against this project.
The fixture omits one newly added metric on BOTH comparison sides and uses an
identical direct shutdown entry because the historical loader has no drain API.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent
TEXT_SUFFIXES = {".gd", ".uid", ".tscn", ".tres", ".gdshader", ".gdshaderinc", ".godot", ".cfg", ".json", ".import"}


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    args = parser.parse_args()
    revision = git("rev-parse", "--verify", args.revision + "^{commit}").decode().strip()
    destination = args.destination.resolve()
    if not destination.is_relative_to((ROOT / "dev_tools/output").resolve()):
        raise SystemExit("Destination must be a fresh child of dev_tools/output")
    if destination.exists():
        raise SystemExit("Refusing to overwrite an existing comparison project")
    records = []
    for entry in git("ls-tree", "-r", "-z", revision).split(b"\0"):
        if not entry:
            continue
        descriptor, name = entry.split(b"\t", 1)
        mode, kind, oid = descriptor.decode().split()
        relative = Path(os.fsdecode(name))
        if relative.parts[0] not in {"scene", "resources", "addons"} and str(relative) not in {
            "project.godot", "run_state.gd", "run_state.gd.uid", "default_bus_layout.tres", "icon.svg", "icon.svg.import"
        }:
            continue
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise SystemExit(f"Unsupported tree member: {relative}")
        records.append((relative, oid))
    destination.mkdir(parents=True)
    metadata = {"revision": revision, "comparison_adapter": "storage-metric-omitted/direct-shutdown", "sources": []}
    assets = [p for p, _ in records if p.suffix not in TEXT_SUFFIXES and (ROOT / p).is_file()]
    asset_hashes = subprocess.check_output(["git", "-C", str(ROOT), "hash-object", "--stdin-paths"], input=("\n".join(p.as_posix() for p in assets) + "\n").encode("utf-8")).decode().splitlines()
    if len(asset_hashes) != len(assets):
        raise SystemExit("Incomplete asset hashing")
    current_asset_oids = dict(zip(assets, asset_hashes))
    with subprocess.Popen(["git", "-C", str(ROOT), "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as blobs:
        for relative, oid in records:
            source = ROOT / relative
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            # All code/config is copied from Git, regardless of working edits.
            if current_asset_oids.get(relative) == oid:
                os.link(source, target)
            else:
                blobs.stdin.write((oid + "\n").encode("ascii"))
                blobs.stdin.flush()
                header = blobs.stdout.readline().decode().strip().split()
                if len(header) != 3 or header[0] != oid or header[1] != "blob":
                    raise SystemExit(f"Unexpected Git object response: {header}")
                payload = blobs.stdout.read(int(header[2]))
                if len(payload) != int(header[2]) or blobs.stdout.read(1) != b"\n":
                    raise SystemExit("Truncated Git blob")
                target.write_bytes(payload)
            if relative.suffix in TEXT_SUFFIXES:
                metadata["sources"].append({"path": relative.as_posix(), "git_blob": oid, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    cache = ROOT / ".godot"
    # PowerShell's native Junction cmdlet gives explicit paths, without cmd /c
    # or string-composed filesystem operations.
    quoted_link = str(destination / ".godot").replace("'", "''")
    quoted_target = str(cache).replace("'", "''")
    subprocess.run(["powershell", "-NoProfile", "-Command", f"New-Item -ItemType Junction -Path '{quoted_link}' -Target '{quoted_target}' | Out-Null"], check=True)
    fixture_root = destination / "dev_tools"
    fixture_root.mkdir()
    for name in ("tower_density_probe.gd", "tower_density_fixture.gd", "tower_density_enemy_cohort.gd", "tower_density_release_entry.gd", "tower_density_release_entry.tscn"):
        shutil.copy2(ROOT / "dev_tools" / name, fixture_root / name)
    fixture_path = fixture_root / "tower_density_fixture.gd"
    fixture = fixture_path.read_text(encoding="utf-8")
    metric_line = '\t\t"production_storage_metrics": runtime.production_coordinator.get_storage_totals_metrics(),\n'
    if fixture.count(metric_line) != 1:
        raise SystemExit("Unexpected fixture storage metric")
    fixture_path.write_text(fixture.replace(metric_line, ""), encoding="utf-8")
    entry_path = fixture_root / "tower_density_release_entry.gd"
    entry = entry_path.read_text(encoding="utf-8")
    shutdown = 'get_tree().root.get_node("PublicRoomLease").call("request_application_shutdown", int(result["exit_code"]))'
    if entry.count(shutdown) != 1:
        raise SystemExit("Unexpected release entry shutdown")
    entry_path.write_text(entry.replace(shutdown, 'get_tree().quit(int(result["exit_code"]))'), encoding="utf-8")
    config_path = destination / "project.godot"
    config = config_path.read_text(encoding="utf-8")
    original = 'run/main_scene="res://scene/main_menu.tscn"'
    if config.count(original) != 1:
        raise SystemExit("Unexpected historical main scene")
    config_path.write_text(config.replace(original, 'run/main_scene="res://dev_tools/tower_density_release_entry.tscn"'), encoding="utf-8")
    shutil.copy2(args.template.resolve(), destination / "Godot_release.exe")
    metadata["fixture_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in fixture_root.iterdir() if p.is_file()}
    metadata["executable_sha256"] = hashlib.sha256((destination / "Godot_release.exe").read_bytes()).hexdigest()
    (destination / "historical_source_manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"HISTORICAL_DENSITY_READY revision={revision} files={len(records)} destination={destination}")


if __name__ == "__main__":
    main()
