#!/usr/bin/env python3
"""Publish the approved elite shield-bearer atlases byte-for-byte.

The preview pipeline remains the only pixel authoring path.  This writer is
the explicit fourth-gate bridge into ``resources``: it pins the pending
manifest and both final PNG byte streams, refuses unapproved selections, and
does not decode/resample before writing runtime files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_shield_bearer_elite"
)
RUNTIME_DIR = ROOT / "resources" / "texture" / "enemy" / "mechanical_life"
MANIFEST = enemy_asset_report_path("combat_robot_shield_bearer_elite_final_candidate_manifest.json")
REPORT = (
    enemy_asset_report_path("combat_robot_shield_bearer_elite_final_preview_report.json")
)

PENDING_MANIFEST_SHA256 = (
    "6c93b38f8bd95fe2b2b546b6f15be4f1b2ee773120059d1ca3e01c45ff9dc14d"
)
EXPECTED_REPORT_SHA256 = (
    "1703fa96a8db47eef05c9766e59761f35556f8e4d4da4d4bc610e4757984c07d"
)
EXPECTED_SELECTION = {
    "approved_anchor": "h1c",
    "approved_animation_selection": {
        "move": "m1",
        "shield_states": "r1",
        "death": "d1",
    },
    "approved_fx_selection": {"block": "b1", "break": "x1"},
}
ASSETS = {
    "main_atlas": {
        "source": SOURCE_DIR / "combat_robot_shield_bearer_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_shield_bearer_elite.png",
        "sha256": "7f36a88b08f5cdb3e37817f9aa4da3b53a09a8ffbef9863683db77dcd01bcf57",
        "size": (256, 256),
    },
    "fx_atlas": {
        "source": SOURCE_DIR / "combat_robot_shield_bearer_elite_fx_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_shield_bearer_elite_fx.png",
        "sha256": "7547a4a5993cfd9373875341afe615cded24967a464f41ba71a2f798721cb01f",
        "size": (256, 32),
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


def assert_runtime_target(path: Path) -> None:
    runtime_root = RUNTIME_DIR.resolve()
    resolved = path.resolve()
    if resolved.parent != runtime_root:
        raise AssertionError(f"runtime texture target escaped locked directory: {path}")


def validate_png(path: Path, expected_sha: str, expected_size: tuple[int, int]) -> bytes:
    if not path.is_file():
        raise FileNotFoundError(path)
    actual_sha = sha256(path)
    if actual_sha != expected_sha:
        raise AssertionError(f"approved PNG SHA drifted: {relative(path)} {actual_sha}")
    with Image.open(path) as image:
        if image.mode != "RGBA" or image.size != expected_size:
            raise AssertionError(
                f"approved PNG contract drifted: {relative(path)} {image.mode} {image.size}"
            )
        pixels = tuple(image.getdata())
    if {pixel[3] for pixel in pixels} - {0, 255}:
        raise AssertionError(f"partial Alpha in approved PNG: {relative(path)}")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError(f"dirty transparent RGB in approved PNG: {relative(path)}")
    return path.read_bytes()


def validate_manifest(payload: dict[str, object], raw_sha: str) -> bool:
    for key, expected in EXPECTED_SELECTION.items():
        if payload.get(key) != expected:
            raise AssertionError(f"approved final selection drifted at {key}")
    if payload.get("imagegen_pixels_imported") is not False:
        raise AssertionError("runtime publication must not import ImageGen pixels")
    if payload.get("report") != relative(REPORT):
        raise AssertionError("final preview report path drifted")
    if not REPORT.is_file() or sha256(REPORT) != EXPECTED_REPORT_SHA256:
        raise AssertionError("final preview report file certificate drifted")
    if payload.get("report_sha256") != EXPECTED_REPORT_SHA256:
        raise AssertionError("final preview report certificate drifted")
    for key, contract in ASSETS.items():
        record = payload.get(key)
        if not isinstance(record, dict):
            raise AssertionError(f"missing manifest asset record: {key}")
        if record.get("path") != relative(contract["source"]):
            raise AssertionError(f"manifest source path drifted: {key}")
        if record.get("sha256") != contract["sha256"]:
            raise AssertionError(f"manifest source SHA drifted: {key}")
        if record.get("size") != list(contract["size"]):
            raise AssertionError(f"manifest source size drifted: {key}")

    stage = payload.get("stage")
    if stage == "final_runtime_candidate_pending_fourth_human_gate":
        if raw_sha != PENDING_MANIFEST_SHA256:
            raise AssertionError(f"pending final manifest SHA drifted: {raw_sha}")
        if payload.get("final_human_approved") is not False:
            raise AssertionError("pending manifest unexpectedly claims final approval")
        if payload.get("runtime_written") is not False:
            raise AssertionError("pending manifest unexpectedly claims a runtime write")
        return False
    if stage != "final_candidate_approved_runtime_written":
        raise AssertionError(f"unexpected final manifest stage: {stage!r}")
    if payload.get("approval_source_manifest_sha256") != PENDING_MANIFEST_SHA256:
        raise AssertionError("runtime manifest lost its pending-source certificate")
    if payload.get("final_human_approved") is not True:
        raise AssertionError("runtime manifest lost final approval")
    if payload.get("runtime_written") is not True:
        raise AssertionError("runtime manifest lost runtime-written state")
    return True


def write_exact(path: Path, payload: bytes, expected_sha: str) -> None:
    assert_runtime_target(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file() or sha256(path) != expected_sha:
        path.write_bytes(payload)
    if sha256(path) != expected_sha or path.read_bytes() != payload:
        raise AssertionError(f"runtime PNG is not the approved byte stream: {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve-final",
        action="store_true",
        help="Confirm the approved H1C/M1/R1/D1/B1/X1 fourth-gate candidate.",
    )
    args = parser.parse_args()
    if not args.approve_final:
        raise SystemExit("Refusing runtime write without --approve-final")
    if not MANIFEST.is_file():
        raise FileNotFoundError(MANIFEST)

    raw_sha = sha256(MANIFEST)
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    already_integrated = validate_manifest(manifest, raw_sha)

    runtime_assets: dict[str, dict[str, object]] = {}
    for name, contract in ASSETS.items():
        source_bytes = validate_png(
            contract["source"], contract["sha256"], contract["size"]
        )
        write_exact(contract["runtime"], source_bytes, contract["sha256"])
        runtime_assets[name] = {
            "source": relative(contract["source"]),
            "path": relative(contract["runtime"]),
            "sha256": contract["sha256"],
            "size": list(contract["size"]),
            "byte_identical": True,
        }

    expected_runtime_assets = manifest.get("runtime_assets")
    if already_integrated and expected_runtime_assets != runtime_assets:
        raise AssertionError("integrated runtime asset certificate drifted")

    manifest.update(
        {
            "stage": "final_candidate_approved_runtime_written",
            "preview_only": False,
            "final_human_approved": True,
            "runtime_written": True,
            "approval_source_manifest_sha256": PENDING_MANIFEST_SHA256,
            "runtime_assets": runtime_assets,
        }
    )
    rendered = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    MANIFEST.write_text(rendered, encoding="utf-8", newline="\n")

    print("Published approved elite shield-bearer atlases:")
    for name, record in runtime_assets.items():
        print(f"  {name}: {record['path']} {record['sha256']}")
    print(f"  manifest: {relative(MANIFEST)} {sha256(MANIFEST)}")


if __name__ == "__main__":
    main()
