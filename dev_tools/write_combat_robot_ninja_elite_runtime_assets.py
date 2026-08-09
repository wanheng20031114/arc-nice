#!/usr/bin/env python3
"""Publish the fourth-gate approved elite ninja atlas byte-for-byte."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/combat_robot_ninja_elite"
PREVIEW_DIR = ROOT / "dev_assets/generated_previews"
FINAL_ATLAS = SOURCE_DIR / "combat_robot_ninja_elite_final_candidate_atlas.png"
FINAL_MANIFEST = SOURCE_DIR / "combat_robot_ninja_elite_final_candidate_manifest.json"
FINAL_REPORT = PREVIEW_DIR / "combat_robot_ninja_elite_final_candidate_report.json"
RUNTIME_TEXTURE = ROOT / "resources/texture/enemy/mechanical_life/combat_robot_ninja_elite.png"
RUNTIME_TEXTURE_IMPORT = Path(str(RUNTIME_TEXTURE) + ".import")
ORDINARY_ANIMATION = ROOT / "resources/animation/combat_robot_ninja.tres"
RUNTIME_ANIMATION = ROOT / "resources/animation/combat_robot_ninja_elite.tres"
CONFIG_SCRIPT = ROOT / "resources/config/enemies/combat_robot_ninja_elite_config.gd"
CONFIG_SCRIPT_UID = Path(str(CONFIG_SCRIPT) + ".uid")
CONFIG_RESOURCE = ROOT / "resources/config/enemies/combat_robot_ninja_elite.tres"
ELITE_SCENE = ROOT / "scene/enemy/mechanical_life/combat_robot_ninja_elite.tscn"

PENDING_MANIFEST_SHA256 = "08c31b54c97ffffdb67e114e74c60fba219443da4b44461ca5eedb55a2ab98a3"
PENDING_REPORT_SHA256 = "8b2e3a9da05fc69a6796284917dd27c0eea32769943af0a0489767df0f92627b"
FINAL_ATLAS_SHA256 = "6c0f50f2e02be51264ba92b269d26366653a0608cbed2b186e6c43c8ae2bd23b"
FINAL_ATLAS_RGBA_SHA256 = "5fc943f0369c1e6a6f26f374c5c07542e2d92dd780e9a8ea7157220dca7001d3"
ORDINARY_ANIMATION_SHA256 = "af187eafdfad565dcd9072575f50dd4007816ccc422d94bf086f3a5ecf88811c"
CORE_FILE_LOCKS = {
    CONFIG_SCRIPT: "a67d79e8ecc80a6a3f9b54e2e68a4fd6ada25f1bd1ea3e794c96df142898ea67",
    CONFIG_RESOURCE: "68044a27a1c712eead2692c784eee1431c5456880bc150576fe8bb71725a1aff",
    ELITE_SCENE: "8ea0212ef02cb1d8c182857c9293a10d9aa6a0c2a2e5c389ac7f943108df0b55",
}
EXPECTED_GATE3 = {
    "manifest_sha256": "ba3e9338e2515a1cad5d414639bacb9276a4b8019007ea47f893b95ea923e759",
    "report_sha256": "67ba9810e813836e6984b80744bd35bb173b71280db55572fa2c73e33c5c4c32",
}
APPROVED_SELECTION = {"move": "m1", "boost": "s2", "death": "d1"}
PENDING_STAGE = "final_candidate_pending_fourth_human_gate"
INTEGRATED_STAGE = "final_candidate_approved_runtime_written"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def assert_runtime_target(path: Path) -> None:
    resources = (ROOT / "resources").resolve()
    resolved = path.resolve()
    if resources not in resolved.parents:
        raise AssertionError(f"Runtime target escaped resources: {path}")


def load_json(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise AssertionError(f"Expected a JSON object: {path}")
    return payload


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def validate_candidate_png() -> bytes:
    if sha256(FINAL_ATLAS) != FINAL_ATLAS_SHA256:
        raise AssertionError("Approved final atlas file SHA drifted")
    with Image.open(FINAL_ATLAS) as opened:
        image = opened.convert("RGBA")
    if image.size != (320, 120) or rgba_sha256(image) != FINAL_ATLAS_RGBA_SHA256:
        raise AssertionError("Approved final atlas decoded pixels drifted")
    pixels = tuple(image.getdata())
    if {pixel[3] for pixel in pixels} - {0, 255}:
        raise AssertionError("Approved final atlas contains partial alpha")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError("Approved final atlas contains dirty transparent RGB")
    return FINAL_ATLAS.read_bytes()


def validate_core_files() -> None:
    for path, expected in CORE_FILE_LOCKS.items():
        if not path.is_file() or sha256(path) != expected:
            raise AssertionError(f"Elite ninja core file lock drifted: {relative(path)}")


def validate_preview_chain(
    manifest: dict[str, object],
    report: dict[str, object],
    manifest_sha: str,
    report_sha: str,
) -> bool:
    if manifest.get("approved_animation_selection") != APPROVED_SELECTION:
        raise AssertionError("Final approved M1/S2/D1 selection drifted")
    if manifest.get("native_atlas", {}).get("path") != relative(FINAL_ATLAS):
        raise AssertionError("Final atlas path certificate drifted")
    if manifest.get("native_atlas", {}).get("sha256") != FINAL_ATLAS_SHA256:
        raise AssertionError("Final atlas SHA certificate drifted")
    gate3 = manifest.get("gate3_certificate")
    if not isinstance(gate3, dict):
        raise AssertionError("Final manifest lost the third-gate certificate")
    for key, expected in EXPECTED_GATE3.items():
        if gate3.get(key) != expected:
            raise AssertionError(f"Third-gate certificate drifted: {key}")

    if manifest.get("stage") == PENDING_STAGE:
        if manifest_sha != PENDING_MANIFEST_SHA256 or report_sha != PENDING_REPORT_SHA256:
            raise AssertionError("Pending fourth-gate manifest/report SHA drifted")
        if report.get("stage") != PENDING_STAGE:
            raise AssertionError("Pending fourth-gate report stage drifted")
        if manifest.get("report_sha256") != PENDING_REPORT_SHA256:
            raise AssertionError("Pending fourth-gate report hash chain drifted")
        if manifest.get("final_human_approved") is not False or report.get("final_human_approved") is not False:
            raise AssertionError("Pending fourth gate unexpectedly claims approval")
        if manifest.get("runtime_written") is not False or report.get("runtime_written") is not False:
            raise AssertionError("Pending fourth gate unexpectedly claims runtime output")
        return False

    if manifest.get("stage") != INTEGRATED_STAGE or report.get("stage") != INTEGRATED_STAGE:
        raise AssertionError("Unexpected elite ninja final/runtime stage")
    if manifest.get("approval_source_manifest_sha256") != PENDING_MANIFEST_SHA256:
        raise AssertionError("Integrated manifest lost the pending manifest certificate")
    if report.get("approval_source_report_sha256") != PENDING_REPORT_SHA256:
        raise AssertionError("Integrated report lost the pending report certificate")
    if manifest.get("report_sha256") != report_sha:
        raise AssertionError("Integrated report hash chain drifted")
    if manifest.get("final_human_approved") is not True or report.get("final_human_approved") is not True:
        raise AssertionError("Integrated fourth-gate approval flag drifted")
    if manifest.get("runtime_written") is not True or report.get("runtime_written") is not True:
        raise AssertionError("Integrated runtime-written flag drifted")
    return True


def write_exact_texture(payload: bytes) -> None:
    assert_runtime_target(RUNTIME_TEXTURE)
    RUNTIME_TEXTURE.parent.mkdir(parents=True, exist_ok=True)
    if not RUNTIME_TEXTURE.is_file() or sha256(RUNTIME_TEXTURE) != FINAL_ATLAS_SHA256:
        RUNTIME_TEXTURE.write_bytes(payload)
    if RUNTIME_TEXTURE.read_bytes() != payload or sha256(RUNTIME_TEXTURE) != FINAL_ATLAS_SHA256:
        raise AssertionError("Runtime texture is not the approved byte stream")


def derive_animation_resource() -> str:
    if sha256(ORDINARY_ANIMATION) != ORDINARY_ANIMATION_SHA256:
        raise AssertionError("Ordinary ninja SpriteFrames contract drifted")
    lines = ORDINARY_ANIMATION.read_text(encoding="utf-8").splitlines()
    lines[0] = '[gd_resource type="SpriteFrames" format=3]'
    ordinary_path = "res://resources/texture/enemy/mechanical_life/combat_robot_ninja.png"
    elite_path = "res://resources/texture/enemy/mechanical_life/combat_robot_ninja_elite.png"
    matches = [index for index, line in enumerate(lines) if ordinary_path in line]
    if len(matches) != 1:
        raise AssertionError("Ordinary SpriteFrames texture binding count drifted")
    lines[matches[0]] = f'[ext_resource type="Texture2D" path="{elite_path}" id="1_texture"]'
    rendered = "\n".join(lines) + "\n"
    for name, fps, loop in (("move", "20.0", "true"), ("boost", "24.0", "true"), ("death", "12.0", "false")):
        marker = f'"name": &"{name}",\n"speed": {fps}'
        if marker not in rendered or f'"loop": {loop},\n"name": &"{name}"' not in rendered:
            raise AssertionError(f"Derived SpriteFrames lost {name} timing/loop contract")
    if rendered.count("filter_clip = true") != 24:
        raise AssertionError("Derived SpriteFrames lost AtlasTexture filter_clip")
    assert_runtime_target(RUNTIME_ANIMATION)
    RUNTIME_ANIMATION.parent.mkdir(parents=True, exist_ok=True)
    RUNTIME_ANIMATION.write_text(rendered, encoding="utf-8", newline="\n")
    return sha256(RUNTIME_ANIMATION)


def uid_record(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    content = path.read_text(encoding="utf-8")
    match = re.search(r"uid://[a-z0-9]+", content)
    return {"path": relative(path), "sha256": sha256(path), "uid": match.group(0) if match else None}


def collect_runtime_assets(animation_sha: str) -> dict[str, object]:
    assets: dict[str, object] = {
        "texture": {"source": relative(FINAL_ATLAS), "path": relative(RUNTIME_TEXTURE), "sha256": FINAL_ATLAS_SHA256, "size": [320, 120], "byte_identical": True},
        "animation": {"path": relative(RUNTIME_ANIMATION), "sha256": animation_sha, "animations": {"move": [8, 20.0, True], "boost": [8, 24.0, True], "death": [8, 12.0, False]}},
        "config_script": {"path": relative(CONFIG_SCRIPT), "sha256": CORE_FILE_LOCKS[CONFIG_SCRIPT]},
        "config": {"path": relative(CONFIG_RESOURCE), "sha256": CORE_FILE_LOCKS[CONFIG_RESOURCE]},
        "scene": {"path": relative(ELITE_SCENE), "sha256": CORE_FILE_LOCKS[ELITE_SCENE], "pure_inherited_override": True},
    }
    texture_import = uid_record(RUNTIME_TEXTURE_IMPORT)
    if texture_import is not None:
        assets["texture_import"] = texture_import
    config_uid = uid_record(CONFIG_SCRIPT_UID)
    if config_uid is not None:
        assets["config_script_uid"] = config_uid
    return assets


def update_certificates(
    manifest: dict[str, object],
    report: dict[str, object],
    runtime_assets: dict[str, object],
) -> None:
    runtime_paths = [str(record["path"]) for record in runtime_assets.values() if isinstance(record, dict) and "path" in record]
    approval = {
        "decision": "approved",
        "approved_selection": APPROVED_SELECTION,
        "pending_manifest_sha256": PENDING_MANIFEST_SHA256,
        "pending_report_sha256": PENDING_REPORT_SHA256,
        "imagegen_pixels_imported": False,
    }
    checks = report.get("checks")
    if isinstance(checks, dict):
        checks["final_human_approval_recorded"] = True
        checks["runtime_written"] = True
    report.update({
        "stage": INTEGRATED_STAGE,
        "preview_only": False,
        "final_human_approved": True,
        "runtime_written": True,
        "runtime_paths_written": runtime_paths,
        "approval_source_manifest_sha256": PENDING_MANIFEST_SHA256,
        "approval_source_report_sha256": PENDING_REPORT_SHA256,
        "final_human_approval": approval,
        "runtime_assets": runtime_assets,
    })
    write_json(FINAL_REPORT, report)
    manifest.update({
        "stage": INTEGRATED_STAGE,
        "preview_only": False,
        "final_human_approved": True,
        "runtime_written": True,
        "runtime_paths_written": runtime_paths,
        "approval_source_manifest_sha256": PENDING_MANIFEST_SHA256,
        "approval_source_report_sha256": PENDING_REPORT_SHA256,
        "final_human_approval": approval,
        "runtime_assets": runtime_assets,
        "report_sha256": sha256(FINAL_REPORT),
    })
    write_json(FINAL_MANIFEST, manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approve-final", action="store_true", help="Record the approved fourth gate and publish runtime assets.")
    args = parser.parse_args()
    if not args.approve_final:
        raise SystemExit("Refusing runtime write without --approve-final")

    manifest_sha = sha256(FINAL_MANIFEST)
    report_sha = sha256(FINAL_REPORT)
    manifest = load_json(FINAL_MANIFEST)
    report = load_json(FINAL_REPORT)
    already_integrated = validate_preview_chain(manifest, report, manifest_sha, report_sha)
    validate_core_files()
    approved_bytes = validate_candidate_png()
    write_exact_texture(approved_bytes)
    animation_sha = derive_animation_resource()
    runtime_assets = collect_runtime_assets(animation_sha)
    if already_integrated:
        previous = manifest.get("runtime_assets")
        if isinstance(previous, dict):
            for key, record in previous.items():
                if key in runtime_assets and runtime_assets[key] != record:
                    raise AssertionError(f"Integrated runtime asset certificate drifted: {key}")
    update_certificates(manifest, report, runtime_assets)
    print(
        "COMBAT_ROBOT_NINJA_ELITE_RUNTIME_ASSETS_OK "
        f"texture={FINAL_ATLAS_SHA256} animation={animation_sha} "
        f"manifest={sha256(FINAL_MANIFEST)}"
    )


if __name__ == "__main__":
    main()
