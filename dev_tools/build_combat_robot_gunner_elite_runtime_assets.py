#!/usr/bin/env python3
"""Promote the approved elite-gunner pixels into deterministic runtime assets.

The writer accepts only the user-approved G1 / M1 / S2 / D2 / B1 candidate
with pinned SHA-256 certificates. It copies both approved PNG byte streams
without resampling and derives SpriteFrames resources from the ordinary
gunner's already audited frame contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_gunner_elite"
)
MANIFEST_PATH = enemy_asset_report_path("combat_robot_gunner_elite_final_candidate_manifest.json")
FINAL_SHEET_PATH = SOURCE_DIR / "combat_robot_gunner_elite_final_candidate.png"
FINAL_BULLET_PATH = SOURCE_DIR / "combat_robot_gunner_elite_bullet_final_candidate.png"
RUNTIME_TEXTURE_DIR = (
    PROJECT_ROOT / "resources" / "texture" / "enemy" / "mechanical_life"
)
RUNTIME_SHEET_PATH = RUNTIME_TEXTURE_DIR / "combat_robot_gunner_elite.png"
RUNTIME_BULLET_PATH = RUNTIME_TEXTURE_DIR / "combat_robot_gunner_elite_bullet.png"
ORDINARY_ANIMATION_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_gunner.tres"
)
ORDINARY_BULLET_ANIMATION_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_gunner_bullet.tres"
)
RUNTIME_ANIMATION_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_gunner_elite.tres"
)
RUNTIME_BULLET_ANIMATION_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot_gunner_elite_bullet.tres"
)

EXPECTED_SELECTION = {
    "move": "M1",
    "fire": "S2",
    "death": "D2",
    "bullet": "B1",
}
EXPECTED_SHEET_SHA256 = (
    "5c19a616ab277c27df25089a20ba9260deb37428bd531856a48b844f8284b03f"
)
EXPECTED_BULLET_SHA256 = (
    "600016b26f904bdde24485474100ed91757c3a8bc479be6e8337e25d6a7fb830"
)
EXPECTED_ORDINARY_ANIMATION_SHA256 = (
    "aead76c5bf3124369cfeb761a7fb5b18158dc0ea76eafb3ff43e303ffc566847"
)
EXPECTED_ORDINARY_BULLET_ANIMATION_SHA256 = (
    "f88f80d8c70f40686c31f732d2f084456ed836f61171360d642b2edbb0f576a4"
)
PENDING_STAGE = "final_candidate_pending_third_human_gate"
INTEGRATED_STAGE = "runtime_integrated"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _assert_runtime_target(path: Path) -> None:
    runtime_root = (PROJECT_ROOT / "resources").resolve()
    resolved = path.resolve()
    if runtime_root not in resolved.parents:
        raise AssertionError(f"Runtime target escaped resources: {path}")


def _load_and_validate_manifest() -> dict[str, object]:
    if not MANIFEST_PATH.is_file():
        raise FileNotFoundError(MANIFEST_PATH)
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("approved_anchor") != "G1":
        raise AssertionError("Elite gunner runtime promotion requires G1")
    if manifest.get("approved_selection") != EXPECTED_SELECTION:
        raise AssertionError("Manifest selection is not approved M1/S2/D2/B1")

    stage = str(manifest.get("stage", ""))
    integrated = (
        stage == INTEGRATED_STAGE
        and manifest.get("final_human_approved") is True
        and manifest.get("runtime_written") is True
    )
    if not integrated and stage != PENDING_STAGE:
        raise AssertionError(f"Unexpected approval stage: {stage!r}")

    third_stage = manifest.get("third_stage")
    if not isinstance(third_stage, dict):
        raise AssertionError("Manifest third-stage record is missing")
    if third_stage.get("selection") != EXPECTED_SELECTION:
        raise AssertionError("Third-stage selection changed")
    if third_stage.get("final_sheet") != _relative(FINAL_SHEET_PATH):
        raise AssertionError("Final sheet path changed")
    if third_stage.get("final_sheet_size") != [256, 192]:
        raise AssertionError("Final sheet size certificate changed")
    if third_stage.get("final_sheet_sha256") != EXPECTED_SHEET_SHA256:
        raise AssertionError("Final sheet SHA certificate changed")
    if third_stage.get("final_bullet") != _relative(FINAL_BULLET_PATH):
        raise AssertionError("Final bullet path changed")
    if third_stage.get("final_bullet_size") != [36, 8]:
        raise AssertionError("Final bullet size certificate changed")
    if third_stage.get("final_bullet_sha256") != EXPECTED_BULLET_SHA256:
        raise AssertionError("Final bullet SHA certificate changed")
    return manifest


def _validate_png(path: Path, size: tuple[int, int], expected_sha: str) -> bytes:
    if not path.is_file():
        raise FileNotFoundError(path)
    actual_sha = _sha256(path)
    if actual_sha != expected_sha:
        raise AssertionError(f"Approved PNG SHA changed: {actual_sha} ({path})")
    with Image.open(path) as image:
        if image.mode != "RGBA" or image.size != size:
            raise AssertionError(
                f"Approved PNG is {image.mode} {image.size}, expected RGBA {size}"
            )
        pixels = tuple(image.getdata())
    if {pixel[3] for pixel in pixels} - {0, 255}:
        raise AssertionError(f"Approved PNG contains partial alpha: {path}")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError(f"Approved PNG contains dirty transparent RGB: {path}")
    return path.read_bytes()


def _write_exact_runtime_png(path: Path, payload: bytes, expected_sha: str) -> None:
    _assert_runtime_target(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    if _sha256(path) != expected_sha:
        raise AssertionError(f"Runtime PNG differs from approved bytes: {path}")


def _derive_animation_resource(
    template_path: Path,
    expected_template_sha: str,
    ordinary_texture_path: str,
    elite_texture_path: str,
    target_path: Path,
) -> str:
    if _sha256(template_path) != expected_template_sha:
        raise AssertionError(f"Ordinary animation contract changed: {template_path}")
    lines = template_path.read_text(encoding="utf-8").splitlines()
    if not lines or not lines[0].startswith('[gd_resource type="SpriteFrames"'):
        raise AssertionError(f"Unexpected SpriteFrames header: {template_path}")
    lines[0] = '[gd_resource type="SpriteFrames" format=3]'

    matching_lines = [
        index for index, line in enumerate(lines) if ordinary_texture_path in line
    ]
    if len(matching_lines) != 1:
        raise AssertionError(
            f"Expected one ordinary texture binding, got {len(matching_lines)}"
        )
    lines[matching_lines[0]] = (
        '[ext_resource type="Texture2D" path="'
        + elite_texture_path
        + '" id="1_texture"]'
    )
    rendered = "\n".join(lines) + "\n"
    if ordinary_texture_path in rendered:
        raise AssertionError("Derived animation still references ordinary texture")
    _assert_runtime_target(target_path)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(rendered, encoding="utf-8", newline="\n")
    return _sha256(target_path)


def _record_runtime_integration(
    manifest: dict[str, object],
    animation_sha: str,
    bullet_animation_sha: str,
) -> None:
    runtime_resources = {
        "sheet": {
            "path": _relative(RUNTIME_SHEET_PATH),
            "sha256": EXPECTED_SHEET_SHA256,
        },
        "bullet": {
            "path": _relative(RUNTIME_BULLET_PATH),
            "sha256": EXPECTED_BULLET_SHA256,
        },
        "animation": {
            "path": _relative(RUNTIME_ANIMATION_PATH),
            "sha256": animation_sha,
        },
        "bullet_animation": {
            "path": _relative(RUNTIME_BULLET_ANIMATION_PATH),
            "sha256": bullet_animation_sha,
        },
    }
    third_stage = manifest["third_stage"]
    assert isinstance(third_stage, dict)
    third_stage.update(
        {
            "status": "approved_and_written_to_runtime",
            "final_human_approved": True,
            "runtime_written": True,
            "runtime_resources": runtime_resources,
        }
    )
    manifest.update(
        {
            "stage": INTEGRATED_STAGE,
            "status": "approved_and_written_to_runtime",
            "final_human_approved": True,
            "runtime_written": True,
            "preview_only": False,
            "runtime_approval": {
                "approved_anchor": "G1",
                "approved_selection": dict(EXPECTED_SELECTION),
                "runtime_resources": runtime_resources,
                "imagegen_pixels_imported": False,
            },
        }
    )
    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def build(confirm_final_human_approval: bool) -> None:
    if not confirm_final_human_approval:
        raise PermissionError(
            "Refusing runtime promotion without --confirm-final-human-approval"
        )
    manifest = _load_and_validate_manifest()
    sheet_bytes = _validate_png(
        FINAL_SHEET_PATH,
        (256, 192),
        EXPECTED_SHEET_SHA256,
    )
    bullet_bytes = _validate_png(
        FINAL_BULLET_PATH,
        (36, 8),
        EXPECTED_BULLET_SHA256,
    )
    _write_exact_runtime_png(
        RUNTIME_SHEET_PATH,
        sheet_bytes,
        EXPECTED_SHEET_SHA256,
    )
    _write_exact_runtime_png(
        RUNTIME_BULLET_PATH,
        bullet_bytes,
        EXPECTED_BULLET_SHA256,
    )
    animation_sha = _derive_animation_resource(
        ORDINARY_ANIMATION_PATH,
        EXPECTED_ORDINARY_ANIMATION_SHA256,
        "res://resources/texture/enemy/mechanical_life/combat_robot_gunner.png",
        "res://resources/texture/enemy/mechanical_life/combat_robot_gunner_elite.png",
        RUNTIME_ANIMATION_PATH,
    )
    bullet_animation_sha = _derive_animation_resource(
        ORDINARY_BULLET_ANIMATION_PATH,
        EXPECTED_ORDINARY_BULLET_ANIMATION_SHA256,
        "res://resources/texture/enemy/mechanical_life/combat_robot_gunner_bullet.png",
        "res://resources/texture/enemy/mechanical_life/combat_robot_gunner_elite_bullet.png",
        RUNTIME_BULLET_ANIMATION_PATH,
    )
    _record_runtime_integration(manifest, animation_sha, bullet_animation_sha)
    print(
        "COMBAT_ROBOT_GUNNER_ELITE_RUNTIME_ASSETS_OK "
        f"sheet={EXPECTED_SHEET_SHA256} bullet={EXPECTED_BULLET_SHA256} "
        f"animation={animation_sha} bullet_animation={bullet_animation_sha}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--confirm-final-human-approval",
        action="store_true",
        help="Record the explicit third-stage approval and write runtime assets.",
    )
    args = parser.parse_args()
    build(args.confirm_final_human_approval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
