#!/usr/bin/env python3
"""Audit approved large-cardboard runtime texture, import and SpriteFrames."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from PIL import Image

from enemy_asset_report_paths import enemy_asset_report_path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev_assets/source_images/cardboard_monster_large/cardboard_monster_large_final_candidate_atlas.png"
TEXTURE = ROOT / "resources/texture/enemy/artificial_creation/cardboard_monster_large.png"
TEXTURE_IMPORT = Path(str(TEXTURE) + ".import")
NORMAL_TEXTURE_IMPORT = ROOT / "resources/texture/enemy/artificial_creation/cardboard_monster.png.import"
ANIMATION = ROOT / "resources/animation/cardboard_monster_large.tres"
REPORT = enemy_asset_report_path("cardboard_monster_large_final_candidate_report.json")
MANIFEST = enemy_asset_report_path("cardboard_monster_large_final_candidate_manifest.json")
STABILITY = enemy_asset_report_path("cardboard_monster_large_final_candidate_stability.json")

ATLAS_SHA256 = "0c883183710140c2923877447db46f14c19c19ce61b7c92f388e3574f2f161e6"
ATLAS_RGBA_SHA256 = "c15ce57637c39800d78024404d1a9a093fd9b48194f17fa1b65b9d451f561999"
ANIMATION_SHA256 = "e9bac6ff860c23325c46cbe01a89206720ef148387cfb7021800a413dbd7a39f"
IMPORT_SHA256 = "2120213b2788edaba663c068ba6757f3ec32ce4e77969547dadbc447ec5928be"
INTEGRATED_STAGE = "final_candidate_approved_runtime_written"
APPROVED_STAGE = "final_candidate_third_human_gate_approved"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def import_uid(path: Path) -> str:
    match = re.search(r'^uid="([^"]+)"$', path.read_text(encoding="utf-8"), re.MULTILINE)
    if match is None:
        raise AssertionError(f"Texture import lost UID: {path}")
    return match.group(1)


def main() -> None:
    if SOURCE.read_bytes() != TEXTURE.read_bytes():
        raise AssertionError("Runtime large-cardboard texture is not byte-identical to the approved atlas")
    if sha256(SOURCE) != ATLAS_SHA256 or sha256(TEXTURE) != ATLAS_SHA256:
        raise AssertionError("Large-cardboard atlas file SHA drifted")
    with Image.open(TEXTURE) as opened:
        atlas = opened.convert("RGBA")
    if atlas.size != (384, 144):
        raise AssertionError(f"Large-cardboard atlas size drifted: {atlas.size}")
    if hashlib.sha256(atlas.tobytes()).hexdigest() != ATLAS_RGBA_SHA256:
        raise AssertionError("Large-cardboard atlas decoded RGBA drifted")
    pixels = tuple(atlas.getdata())
    if any(pixel[3] not in (0, 255) for pixel in pixels):
        raise AssertionError("Large-cardboard atlas alpha is not binary")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError("Large-cardboard atlas transparent RGB is dirty")

    animation_text = ANIMATION.read_text(encoding="utf-8")
    if sha256(ANIMATION) != ANIMATION_SHA256:
        raise AssertionError("Large-cardboard SpriteFrames SHA drifted")
    if animation_text.count("filter_clip = true") != 24:
        raise AssertionError("Every large-cardboard AtlasTexture must enable filter_clip")
    expected_regions = [
        (column * 48, row * 48)
        for row in range(3)
        for column in range(8)
    ]
    regions = [
        (int(x), int(y))
        for x, y in re.findall(r"region = Rect2\((\d+), (\d+), 48, 48\)", animation_text)
    ]
    if regions != expected_regions:
        raise AssertionError("Large-cardboard AtlasTexture regions drifted")
    for name, fps, loop in (
        ("move", "9.0", "true"),
        ("windup", "9.0", "false"),
        ("slash", "15.0", "false"),
        ("death", "8.0", "false"),
    ):
        if f'"name": &"{name}"' not in animation_text or f'"speed": {fps}' not in animation_text:
            raise AssertionError(f"Large-cardboard animation timing drifted: {name}")
        if re.search(rf'"loop": {loop},\n"name": &"{name}"', animation_text) is None:
            raise AssertionError(f"Large-cardboard animation loop contract drifted: {name}")

    if sha256(TEXTURE_IMPORT) != IMPORT_SHA256:
        raise AssertionError("Large-cardboard texture import SHA drifted")
    import_text = TEXTURE_IMPORT.read_text(encoding="utf-8")
    for marker in ('importer="texture"', 'compress/mode=0', 'mipmaps/generate=false'):
        if marker not in import_text:
            raise AssertionError(f"Large-cardboard texture import lost {marker}")
    if import_uid(TEXTURE_IMPORT) == import_uid(NORMAL_TEXTURE_IMPORT):
        raise AssertionError("Large cardboard must not reuse the ordinary cardboard texture UID")

    report = json.loads(REPORT.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    stability = json.loads(STABILITY.read_text(encoding="utf-8"))
    for payload in (report, manifest):
        if (
            payload.get("stage") != INTEGRATED_STAGE
            or payload.get("third_human_approved") is not True
            or payload.get("final_human_approved") is not True
            or payload.get("runtime_written") is not True
            or payload.get("p1c_written") is not False
            or payload.get("protocol_written") is not False
        ):
            raise AssertionError("Large-cardboard runtime certificate flags drifted")
    if stability.get("stage") != APPROVED_STAGE or stability.get("runtime_written") is not False:
        raise AssertionError("Large-cardboard approved preview stability evidence drifted")
    runtime_assets = manifest.get("runtime_assets", {})
    slash = runtime_assets.get("animation", {}).get("animations", {}).get("slash", {})
    if (
        slash.get("frames") != 5
        or slash.get("damage_frame_local_index") != 1
        or slash.get("damage_frame_source_cell") != {"row": 1, "column": 4}
    ):
        raise AssertionError("Large-cardboard slash damage-frame certificate drifted")
    if runtime_assets.get("texture", {}).get("byte_identical_to_approved_atlas") is not True:
        raise AssertionError("Large-cardboard texture publication certificate drifted")
    print("CARDBOARD_MONSTER_LARGE_ASSET_AUDIT_OK")


if __name__ == "__main__":
    main()
