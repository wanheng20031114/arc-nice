#!/usr/bin/env python3
"""Audit the approved elite ninja atlas, SpriteFrames and afterimage certificate."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev_assets/source_images/combat_robot_ninja_elite"
PREVIEW = ROOT / "dev_assets/generated_previews"
OUTPUT = ROOT / "dev_tools/output/combat_robot_ninja_elite_afterimage"
RUNTIME = ROOT / "resources/texture/enemy/mechanical_life"
ANIMATION = ROOT / "resources/animation/combat_robot_ninja_elite.tres"
SHADER = ROOT / "scene/combat/feedback/shaders/entity_motion_status.gdshader"

CANDIDATE = SOURCE / "combat_robot_ninja_elite_final_candidate_atlas.png"
RUNTIME_ATLAS = RUNTIME / "combat_robot_ninja_elite.png"
ORDINARY_ATLAS = RUNTIME / "combat_robot_ninja.png"
MANIFEST = SOURCE / "combat_robot_ninja_elite_final_candidate_manifest.json"
ANCHOR_MANIFEST = SOURCE / "combat_robot_ninja_elite_anchor_manifest.json"
ANIMATION_MANIFEST = SOURCE / "combat_robot_ninja_elite_animation_manifest.json"
AFTERIMAGE_MANIFEST = SOURCE / "combat_robot_ninja_elite_afterimage_manifest.json"
AFTERIMAGE_REPORT = PREVIEW / "combat_robot_ninja_elite_afterimage_preview_report.json"
FINAL_REPORT = PREVIEW / "combat_robot_ninja_elite_final_candidate_report.json"
RUNTIME_REPORT = OUTPUT / "runtime_report.json"

ATLAS_SHA256 = "6c0f50f2e02be51264ba92b269d26366653a0608cbed2b186e6c43c8ae2bd23b"
ATLAS_RGBA_SHA256 = "5fc943f0369c1e6a6f26f374c5c07542e2d92dd780e9a8ea7157220dca7001d3"
ORDINARY_SHA256 = "f34f15083e48af0179c1d2669a3d22bdfdb33de266d9373cbaa9defa2b434ceb"
GATE_SHA256 = {
    ANCHOR_MANIFEST: "11df368a76d4025aedc6c823bf3e4dfcfc06b59acc25a9427dff82b42b13162e",
    ANIMATION_MANIFEST: "a2589f42897f714ffbd99300b8136c6a9eac30ff5f1aaffb4e85941e7041be61",
    AFTERIMAGE_MANIFEST: "ba3e9338e2515a1cad5d414639bacb9276a4b8019007ea47f893b95ea923e759",
    MANIFEST: "e240ce114db15d9bc6905df385fe4be1ae9e913a04633191a31c7e0ace91e927",
    FINAL_REPORT: "09ba3bf7679b8691b3ecb8699333e4968e1510bbb7fabc601a109805760a083c",
}
RUNTIME_FILE_SHA256 = {
    ANIMATION: "d358cf0f9cdbd5002dc6d9a61d690bad4b3d18addc4bfd38eba74bc243c5bbfd",
    ROOT / "resources/config/enemies/combat_robot_ninja_elite_config.gd":
        "a67d79e8ecc80a6a3f9b54e2e68a4fd6ada25f1bd1ea3e794c96df142898ea67",
    ROOT / "resources/config/enemies/combat_robot_ninja_elite.tres":
        "68044a27a1c712eead2692c784eee1431c5456880bc150576fe8bb71725a1aff",
    ROOT / "scene/enemy/mechanical_life/combat_robot_ninja_elite.tscn":
        "8ea0212ef02cb1d8c182857c9293a10d9aa6a0c2a2e5c389ac7f943108df0b55",
}
ROW_RGBA_SHA256 = {
    "move": "cfb00c5e0c1e330d41a0bfcee6827576b52f39e8a7ca3c6875fb3511eed921ba",
    "boost": "e44ebfa9e6ba7f4cba50a38acf3f114ae87829f8fc1e047b6610243f2936cb37",
    "death": "616bff1518b607e5f58e60e1375eeb0fc339f41ec92e4280062d739757357ed0",
}
APPROVED_STRIPS = {
    "move": SOURCE / "combat_robot_ninja_elite_move_m1_candidate_native.png",
    "boost": SOURCE / "combat_robot_ninja_elite_boost_s2_candidate_native.png",
    "death": SOURCE / "combat_robot_ninja_elite_death_d1_candidate_native.png",
}
ANIMATION_CONTRACT = {
    "move": (0, 20.0, True),
    "boost": (1, 24.0, True),
    "death": (2, 12.0, False),
}
TRANSPARENT = (0, 0, 0, 0)
OLD_ACCENTS = {
    (102, 25, 20, 255),
    (190, 48, 31, 255),
    (239, 92, 34, 255),
}
ALLOWED_COLORS = {
    TRANSPARENT,
    (21, 22, 19, 255),
    (29, 28, 30, 255),
    (55, 59, 63, 255),
    (82, 88, 94, 255),
    (112, 121, 128, 255),
    (151, 159, 164, 255),
    (190, 196, 198, 255),
    (226, 229, 226, 255),
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba(path: Path) -> Image.Image:
    with Image.open(path) as opened:
        if opened.mode != "RGBA":
            raise AssertionError(f"{path.name}: expected RGBA, got {opened.mode}")
        return opened.copy()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.tobytes()).hexdigest()


def frame(sheet: Image.Image, column: int, row: int) -> Image.Image:
    return sheet.crop((column * 40, row * 40, (column + 1) * 40, (row + 1) * 40))


def component_count_8(image: Image.Image) -> int:
    remaining = {
        (x, y)
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] == 255
    }
    count = 0
    while remaining:
        count += 1
        stack = [remaining.pop()]
        while stack:
            x, y = stack.pop()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    point = (x + dx, y + dy)
                    if point in remaining:
                        remaining.remove(point)
                        stack.append(point)
    return count


def assert_manifest() -> None:
    for path, expected in GATE_SHA256.items():
        if sha256(path) != expected:
            raise AssertionError(f"approval certificate drifted: {path.name}")
    anchor = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    animation_gate = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    if (
        anchor.get("stage") != "first_human_gate_approved"
        or str(anchor.get("approved_selection", "")).lower() != "n1c"
        or animation_gate.get("stage") != "second_human_gate_approved"
        or animation_gate.get("approved_animation_selection")
        != {"move": "m1", "boost": "s2", "death": "d1"}
    ):
        raise AssertionError("first/second human-gate certificate drifted")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if (
        manifest.get("stage") != "final_candidate_approved_runtime_written"
        or manifest.get("approved_anchor") != "n1c"
        or manifest.get("approved_animation_selection")
        != {"move": "m1", "boost": "s2", "death": "d1"}
        or manifest.get("final_human_approved") is not True
        or manifest.get("runtime_written") is not True
        or manifest.get("preview_only") is not False
        or manifest.get("imagegen_pixels_imported") is not False
    ):
        raise AssertionError("final approval/runtime certificate drifted")
    texture = manifest.get("runtime_assets", {}).get("texture", {})
    if (
        texture.get("sha256") != ATLAS_SHA256
        or texture.get("byte_identical") is not True
        or texture.get("size") != [320, 120]
    ):
        raise AssertionError("runtime texture certificate drifted")
    if (
        manifest.get("report") != FINAL_REPORT.relative_to(ROOT).as_posix()
        or manifest.get("report_sha256") != GATE_SHA256[FINAL_REPORT]
        or manifest.get("gate3_certificate", {}).get("manifest_sha256")
        != GATE_SHA256[AFTERIMAGE_MANIFEST]
    ):
        raise AssertionError("third/final gate hash chain drifted")
    for path, expected in RUNTIME_FILE_SHA256.items():
        if sha256(path) != expected:
            raise AssertionError(f"runtime file certificate drifted: {path.name}")


def assert_frames(sheet: Image.Image, ordinary: Image.Image) -> None:
    if sheet.size != (320, 120):
        raise AssertionError(f"atlas must be 320x120, got {sheet.size}")
    colors = set(sheet.getdata())
    if not colors <= ALLOWED_COLORS or colors & OLD_ACCENTS:
        raise AssertionError(f"fixed palette drifted: {sorted(colors - ALLOWED_COLORS)}")
    if any(pixel[3] not in (0, 255) for pixel in colors):
        raise AssertionError("alpha must be binary")
    if any(pixel[3] == 0 and pixel != TRANSPARENT for pixel in colors):
        raise AssertionError("transparent RGB must be zero")

    for row, name in enumerate(("move", "boost", "death")):
        strip = sheet.crop((0, row * 40, 320, (row + 1) * 40))
        if rgba_sha(strip) != ROW_RGBA_SHA256[name]:
            raise AssertionError(f"approved {name} decoded row drifted")
        approved = rgba(APPROVED_STRIPS[name])
        if strip.tobytes() != approved.tobytes():
            raise AssertionError(f"runtime {name} is not approved M1/S2/D1 strip")
        for index in range(8):
            candidate = frame(sheet, index, row)
            base = frame(ordinary, index, row)
            bbox = candidate.getchannel("A").getbbox()
            if bbox is None:
                raise AssertionError(f"{name}[{index}] is empty")
            left, top, right, bottom = bbox
            if (
                right - left > 28
                or bottom - top > 28
                or bottom != 32
                or min(left, top, 40 - right, 40 - bottom) < 6
            ):
                raise AssertionError(f"{name}[{index}] bbox/margin/baseline drifted: {bbox}")
            if component_count_8(candidate) != 1:
                raise AssertionError(f"{name}[{index}] blades or reinforcement detached")
            removed = False
            y11_added = False
            for y in range(40):
                for x in range(40):
                    before = base.getpixel((x, y))
                    after = candidate.getpixel((x, y))
                    removed |= before[3] == 255 and after[3] == 0
                    y11_added |= y == 11 and before[3] == 0 and after[3] == 255
            if removed or y11_added:
                raise AssertionError(f"{name}[{index}] ordinary alpha/y11 contract drifted")


def assert_sprite_frames() -> None:
    text = ANIMATION.read_text(encoding="utf-8")
    texture_path = (
        'path="res://resources/texture/enemy/mechanical_life/'
        'combat_robot_ninja_elite.png"'
    )
    if text.count(texture_path) != 1 or text.count("filter_clip = true") != 24:
        raise AssertionError("SpriteFrames atlas/filter_clip binding drifted")
    for name, (row, speed, loop) in ANIMATION_CONTRACT.items():
        if text.count(f'id="AtlasTexture_{name}_') != 8:
            raise AssertionError(f"{name} must declare eight AtlasTexture frames")
        pattern = (
            rf'"loop": {str(loop).lower()},\s*"name": &"{name}",'
            rf'\s*"speed": {speed:.1f}'
        )
        if re.search("".join(pattern), text) is None:
            raise AssertionError(f"{name} FPS/loop contract drifted")
        for index in range(8):
            region = f"region = Rect2({index * 40}, {row * 40}, 40, 40)"
            if text.count(region) != 1:
                raise AssertionError(f"{name}[{index}] atlas region drifted")


def assert_afterimage_certificate() -> None:
    gate = json.loads(AFTERIMAGE_MANIFEST.read_text(encoding="utf-8"))
    report = json.loads(RUNTIME_REPORT.read_text(encoding="utf-8"))
    if gate.get("stage") != "afterimage_third_human_gate_approved" or gate.get("third_human_approved") is not True:
        raise AssertionError("third-gate afterimage approval is missing")
    for key, record in gate.get("outputs", {}).items():
        output = ROOT / record["path"]
        if not output.is_file() or sha256(output) != record["sha256"]:
            raise AssertionError(f"approved afterimage GIF drifted: {key}")
    if report.get("failures") != [] or report.get("godot_real_render") is not True:
        raise AssertionError("Godot afterimage render report did not pass")
    material = report.get("material", {})
    if (
        material.get("created_material_count") != 0
        or material.get("duplicated_material_count") != 0
        or material.get("shared_material_count") != 1
        or material.get("shared_shader_count") != 1
        or material.get("shared_identity") is not True
        or material.get("material_uniforms_unchanged") is not True
        or material.get("set_shader_parameter_call_count") != 0
    ):
        raise AssertionError("afterimage must use one unchanged shared material with instance uniforms")
    direction = report.get("direction_audit", {})
    if (
        max(direction.get("body_changed_pixels", {}).values(), default=1) != 0
        or max(direction.get("trail_body_intersection_pixels", {}).values(), default=1) != 0
        or min(direction.get("trail_only_pixels", {}).values(), default=0) <= 0
        or max(direction.get("original_rgb_oracle_max_channel_error", {}).values(), default=1.0) > 1.0 / 255.0
    ):
        raise AssertionError("tail-only/original-RGB render oracle drifted")
    lifecycle = report.get("lifecycle", {})
    if lifecycle.get("verified") is not True or lifecycle.get("death_tail_zero") is not True:
        raise AssertionError("afterimage status/death cleanup lifecycle drifted")
    shader = SHADER.read_text(encoding="utf-8")
    if (
        "instance uniform float ninja_afterimage_strength" not in shader
        or "instance uniform vec2 ninja_afterimage_direction" not in shader
        or "Ninja afterimages preserve the source body" not in shader
    ):
        raise AssertionError("production shader lost original-RGB tail-only contract")


def main() -> int:
    required = [
        CANDIDATE,
        RUNTIME_ATLAS,
        ORDINARY_ATLAS,
        MANIFEST,
        ANCHOR_MANIFEST,
        ANIMATION_MANIFEST,
        AFTERIMAGE_MANIFEST,
        AFTERIMAGE_REPORT,
        FINAL_REPORT,
        RUNTIME_REPORT,
        ANIMATION,
        SHADER,
        *APPROVED_STRIPS.values(),
        *RUNTIME_FILE_SHA256.keys(),
    ]
    for path in required:
        if not path.is_file():
            raise AssertionError(f"missing required file: {path.relative_to(ROOT)}")
    assert_manifest()
    if sha256(CANDIDATE) != ATLAS_SHA256 or sha256(RUNTIME_ATLAS) != ATLAS_SHA256:
        raise AssertionError("runtime atlas is not the byte-identical approved candidate")
    if CANDIDATE.read_bytes() != RUNTIME_ATLAS.read_bytes():
        raise AssertionError("candidate/runtime PNG byte streams differ")
    if sha256(ORDINARY_ATLAS) != ORDINARY_SHA256:
        raise AssertionError("ordinary ninja runtime atlas was modified")
    atlas = rgba(RUNTIME_ATLAS)
    if rgba_sha(atlas) != ATLAS_RGBA_SHA256:
        raise AssertionError("runtime decoded RGBA certificate drifted")
    assert_frames(atlas, rgba(ORDINARY_ATLAS))
    assert_sprite_frames()
    assert_afterimage_certificate()
    print(
        "COMBAT_ROBOT_NINJA_ELITE_ASSET_AUDIT_OK "
        f"atlas={ATLAS_SHA256} frames=24 selection=N1C/M1/S2/D1"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
