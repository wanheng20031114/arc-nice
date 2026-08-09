#!/usr/bin/env python3
"""Publish the fourth-gate approved elite drone-operator pixel assets.

The review pipeline deliberately keeps candidates under ``dev_assets``.  This
writer is the only bridge into ``resources``: it requires an explicit final
approval flag, verifies every locked candidate byte-for-byte, and copies those
exact PNG bytes without decoding or resampling them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_drone_operator_elite"
)
RUNTIME_DIR = ROOT / "resources" / "texture" / "enemy" / "mechanical_life"
FINAL_SELECTION = SOURCE_DIR / "combat_robot_drone_operator_elite_final_selection.json"
FINAL_MANIFEST = SOURCE_DIR / "combat_robot_drone_operator_elite_final_candidate_manifest.json"

LOCKED_SELECTION = {
    "approved_anchor": "O3",
    "approved_animation_selection": {
        "move": "M1",
        "deploy": "P1",
        "death": "K2",
    },
    "approved_effect_selection": {
        "drone": "V1",
        "target": "T1",
        "explosion": "X1",
    },
}

ASSETS = {
    "operator": {
        "source": SOURCE_DIR / "combat_robot_drone_operator_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_drone_operator_elite.png",
        "sha256": "ec9fdb615610531e24350237cd8aa9556909ba135acae15d53624d0fd9221bd0",
    },
    "drone": {
        "source": SOURCE_DIR / "combat_robot_suicide_drone_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_suicide_drone_elite.png",
        "sha256": "6e3190f928bc5d49fa654bba1f9edd2ee6e071e4d9d21420a8b8a7256fb94c0d",
    },
    "target": {
        "source": SOURCE_DIR / "combat_robot_drone_target_marker_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_drone_target_marker_elite.png",
        "sha256": "8be355f9b24d7920b5cb350addd9af289b698e7c672f39ff7db5e77f19d6d747",
    },
    "explosion": {
        "source": SOURCE_DIR / "combat_robot_mechanical_explosion_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_mechanical_explosion_elite.png",
        "sha256": "c3e2ba275b9151a897b8f0411c59dd7acd9ebc0e37e26bc242e960a13ea571b1",
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def validate_selection(payload: dict) -> None:
    for key, expected in LOCKED_SELECTION.items():
        if payload.get(key) != expected:
            raise AssertionError(f"final selection drifted at {key}")
    if payload.get("imagegen_pixels_imported") is not False:
        raise AssertionError("runtime publication must not import ImageGen pixels")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--approve-final",
        action="store_true",
        help="Confirm that the fourth human gate approved O3/M1/P1/K2/V1/T1/X1.",
    )
    args = parser.parse_args()
    if not args.approve_final:
        raise SystemExit("Refusing runtime write without --approve-final")

    selection = load_json(FINAL_SELECTION)
    manifest = load_json(FINAL_MANIFEST)
    validate_selection(selection)
    validate_selection(manifest)

    runtime_assets: dict[str, dict[str, str]] = {}
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    for name, contract in ASSETS.items():
        source = contract["source"]
        destination = contract["runtime"]
        expected_hash = contract["sha256"]
        actual_hash = sha256(source)
        if actual_hash != expected_hash:
            raise AssertionError(
                f"locked {name} candidate drifted: {actual_hash} != {expected_hash}"
            )
        shutil.copyfile(source, destination)
        runtime_hash = sha256(destination)
        if runtime_hash != expected_hash:
            raise AssertionError(f"runtime {name} was not copied byte-for-byte")
        runtime_assets[name] = {
            "source": relative(source),
            "path": relative(destination),
            "sha256": runtime_hash,
        }

    selection.update(
        {
            "stage": "final_selection_approved_runtime_written",
            "final_human_approved": True,
            "runtime_written": True,
            "runtime_assets": runtime_assets,
        }
    )
    write_json(FINAL_SELECTION, selection)

    manifest.update(
        {
            "stage": "final_candidate_approved_runtime_written",
            "final_human_approved": True,
            "runtime_written": True,
            "runtime_assets": runtime_assets,
        }
    )
    manifest["selection_certificate"] = {
        "path": relative(FINAL_SELECTION),
        "sha256": sha256(FINAL_SELECTION),
    }
    write_json(FINAL_MANIFEST, manifest)

    print("Published approved elite drone-operator assets:")
    for name, contract in runtime_assets.items():
        print(f"  {name}: {contract['path']} {contract['sha256']}")


if __name__ == "__main__":
    main()
