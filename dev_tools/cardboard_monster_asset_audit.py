#!/usr/bin/env python3
"""Audit the approved cardboard-monster runtime texture and SpriteFrames."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev_assets/source_images/cardboard_monster/cardboard_monster_final_candidate_atlas.png"
TEXTURE = ROOT / "resources/texture/enemy/artificial_creation/cardboard_monster.png"
TEXTURE_IMPORT = Path(str(TEXTURE) + ".import")
ANIMATION = ROOT / "resources/animation/cardboard_monster.tres"
REPORT = enemy_asset_report_path("cardboard_monster_final_candidate_report.json")
MANIFEST = enemy_asset_report_path("cardboard_monster_final_candidate_manifest.json")
STABILITY = enemy_asset_report_path("cardboard_monster_final_candidate_stability.json")

ATLAS_SHA256 = "73bad923829c873b83c808954d610735826884e2786a5fb1da21a04240578f2c"
ATLAS_RGBA_SHA256 = "81e4a17fc6288a6204df5e67af864b4fc02e3644eaef92d1ca01b6b7504a44cf"
ANIMATION_SHA256 = "ac9c1e6e1cf3b718dcebf9f21dda04fc3c506c1697b7d181e02ca3b7977ff311"
INTEGRATED_STAGE = "final_candidate_approved_runtime_written"
APPROVED_STAGE = "final_candidate_third_human_gate_approved"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    if SOURCE.read_bytes() != TEXTURE.read_bytes():
        raise AssertionError("Runtime texture is not byte-identical to the approved atlas")
    if sha256(SOURCE) != ATLAS_SHA256 or sha256(TEXTURE) != ATLAS_SHA256:
        raise AssertionError("Cardboard atlas file SHA drifted")
    with Image.open(TEXTURE) as opened:
        atlas = opened.convert("RGBA")
    if atlas.size != (256, 96):
        raise AssertionError(f"Cardboard atlas size drifted: {atlas.size}")
    if hashlib.sha256(atlas.tobytes()).hexdigest() != ATLAS_RGBA_SHA256:
        raise AssertionError("Cardboard atlas decoded RGBA drifted")
    pixels = tuple(atlas.getdata())
    if any(pixel[3] not in (0, 255) for pixel in pixels):
        raise AssertionError("Cardboard atlas alpha is not binary")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError("Cardboard atlas transparent RGB is dirty")

    animation_text = ANIMATION.read_text(encoding="utf-8")
    if sha256(ANIMATION) != ANIMATION_SHA256:
        raise AssertionError("Cardboard SpriteFrames SHA drifted")
    if animation_text.count("filter_clip = true") != 24:
        raise AssertionError("Every cardboard AtlasTexture must enable filter_clip")
    expected_regions = []
    for column in range(8):
        expected_regions.append((column * 32, 0))
    for column in range(8):
        expected_regions.append((column * 32, 32))
    for column in range(8):
        expected_regions.append((column * 32, 64))
    regions = [
        (int(x), int(y))
        for x, y in re.findall(r"region = Rect2\((\d+), (\d+), 32, 32\)", animation_text)
    ]
    if regions != expected_regions:
        raise AssertionError("Cardboard AtlasTexture regions drifted")
    for name, fps, loop in (
        ("move", "12.0", "true"),
        ("windup", "9.0", "false"),
        ("slash", "15.0", "false"),
        ("death", "8.0", "false"),
    ):
        if f'"name": &"{name}"' not in animation_text or f'"speed": {fps}' not in animation_text:
            raise AssertionError(f"Cardboard animation timing drifted: {name}")
        pattern = rf'"loop": {loop},\n"name": &"{name}"'
        if re.search(pattern, animation_text) is None:
            raise AssertionError(f"Cardboard animation loop contract drifted: {name}")

    import_text = TEXTURE_IMPORT.read_text(encoding="utf-8")
    for marker in ('importer="texture"', 'compress/mode=0', 'mipmaps/generate=false'):
        if marker not in import_text:
            raise AssertionError(f"Cardboard texture import contract lost {marker}")

    report = json.loads(REPORT.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    stability = json.loads(STABILITY.read_text(encoding="utf-8"))
    for payload in (report, manifest):
        if (
            payload.get("stage") != INTEGRATED_STAGE
            or payload.get("third_human_approved") is not True
            or payload.get("final_human_approved") is not True
            or payload.get("runtime_written") is not True
        ):
            raise AssertionError("Cardboard runtime certificate flags drifted")
    if stability.get("stage") != APPROVED_STAGE or stability.get("runtime_written") is not False:
        raise AssertionError("Cardboard approved preview stability evidence drifted")
    runtime_animation = manifest.get("runtime_assets", {}).get("animation", {})
    slash_contract = runtime_animation.get("animations", {}).get("slash", {})
    if (
        slash_contract.get("frames") != 5
        or slash_contract.get("damage_frame_local_index") != 1
        or slash_contract.get("damage_frame_source_cell") != {"row": 1, "column": 4}
    ):
        raise AssertionError("Cardboard runtime slash damage-frame certificate drifted")
    print("CARDBOARD_MONSTER_ASSET_AUDIT_OK")


if __name__ == "__main__":
    main()
