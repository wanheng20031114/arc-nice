#!/usr/bin/env python3
"""Publish the approved cardboard-monster atlas and runtime SpriteFrames."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/cardboard_monster"
PREVIEW_DIR = ROOT / "dev_assets/generated_previews"
FINAL_ATLAS = SOURCE_DIR / "cardboard_monster_final_candidate_atlas.png"
FINAL_REPORT = enemy_asset_report_path("cardboard_monster_final_candidate_report.json")
FINAL_MANIFEST = enemy_asset_report_path("cardboard_monster_final_candidate_manifest.json")
FINAL_STABILITY = enemy_asset_report_path("cardboard_monster_final_candidate_stability.json")
FINAL_BUILDER = ROOT / "dev_tools/build_cardboard_monster_final_preview.py"

RUNTIME_TEXTURE = ROOT / "resources/texture/enemy/artificial_creation/cardboard_monster.png"
RUNTIME_TEXTURE_IMPORT = Path(str(RUNTIME_TEXTURE) + ".import")
RUNTIME_ANIMATION = ROOT / "resources/animation/cardboard_monster.tres"
CONFIG_SCRIPT = ROOT / "resources/config/enemies/cardboard_monster_config.gd"
CONFIG_SCRIPT_UID = Path(str(CONFIG_SCRIPT) + ".uid")
CONFIG_RESOURCE = ROOT / "resources/config/enemies/cardboard_monster.tres"
ENEMY_SCRIPT = ROOT / "scene/enemy/artificial_creation/cardboard_monster.gd"
ENEMY_SCRIPT_UID = Path(str(ENEMY_SCRIPT) + ".uid")
ENEMY_SCENE = ROOT / "scene/enemy/artificial_creation/cardboard_monster.tscn"
CAPOO_KNIGHT_SCRIPT = ROOT / "scene/enemy/capoo/capoo_knight.gd"
DAMAGE_TARGET_PROFILE = ROOT / "scene/combat/damage_target_profile.gd"

APPROVED_STAGE = "final_candidate_third_human_gate_approved"
INTEGRATED_STAGE = "final_candidate_approved_runtime_written"
APPROVED_CERTIFICATE_LOCKS = {
    "builder_sha256": "98772cc03d1acbfcc2932e360215b7cdbd5231071679e976aebbf18dfc2c6dd2",
    "report_sha256": "a35112200ef21ec42791fe6878480743db544bd679e421f1b27528e99929c4ff",
    "manifest_sha256": "dae0b6263dfb2a667504327565dd2142ed8f708a8dc74cda38ceb5e328776a49",
    "stability_sha256": "7683b586f1b1bab04cb35d1105a49c4d2aa315ec9d737a363516b59d4fa61dbc",
    "atlas_sha256": "73bad923829c873b83c808954d610735826884e2786a5fb1da21a04240578f2c",
    "atlas_rgba_sha256": "81e4a17fc6288a6204df5e67af864b4fc02e3644eaef92d1ca01b6b7504a44cf",
}
CORE_FILE_LOCKS = {
    CAPOO_KNIGHT_SCRIPT: "83472eaaa0a5d8abe0eba2b1f3f227f8e98002a11b5c66007bf7a13070d41026",
    CONFIG_SCRIPT: "9692b9e6a4e31da27811dbb6cc3fef935cca86bd6917e1cade27cbf91c87ed3b",
    CONFIG_RESOURCE: "eaeb308eaad60ce804385c0b5a58ab66942e87d14a416aae3e635e0ebfc3e9e0",
    ENEMY_SCRIPT: "cb57b806cc45a75091122c9246612fb437a689cd5069f781a8d534a30bee51df",
    ENEMY_SCENE: "8e48d7b5ffb4045deee15974f089a21fd8c918a1fe94f2895d71f5b61dd95ab7",
}
IMPORT_UID_LOCKS = {
    RUNTIME_TEXTURE_IMPORT: "06e2e3cf47f95435fa630f181aa141d58c9e36809d09d96dbf4f643e58474471",
    CONFIG_SCRIPT_UID: "7cfd065159f3cec7df3856cc42130746ae2cdf88b2afb43ac2403e5bf55cc820",
    ENEMY_SCRIPT_UID: "1216d0563734675a6c126ea3ade239ccef35900e5c8a1a8db6a069dc475d1d2f",
}
APPROVED_SELECTION = {"move": "m2", "attack": "a2", "death": "d2"}

ANIMATIONS = (
    ("move", 0, tuple(range(8)), 12.0, True),
    ("windup", 1, (0, 1, 2), 9.0, False),
    ("slash", 1, (3, 4, 5, 6, 7), 15.0, False),
    ("death", 2, tuple(range(8)), 12.0, False),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def load_json(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise AssertionError(f"Expected JSON object: {rel(path)}")
    return payload


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def assert_runtime_target(path: Path) -> None:
    resolved = path.resolve()
    if not any(
        base.resolve() in resolved.parents
        for base in (ROOT / "resources", ROOT / "scene")
    ):
        raise AssertionError(f"Runtime target escaped resources/scene: {path}")


def validate_core_files() -> None:
    for path, expected in CORE_FILE_LOCKS.items():
        if not path.is_file() or sha256(path) != expected:
            raise AssertionError(f"Cardboard runtime core lock drifted: {rel(path)}")
    profile_source = DAMAGE_TARGET_PROFILE.read_text(encoding="utf-8")
    if "var fixed_damage_per_accepted_hit: float = 0.0" not in profile_source:
        raise AssertionError("DamageTargetProfile fixed-hit API is unavailable")
    for path, expected in IMPORT_UID_LOCKS.items():
        if not path.is_file() or sha256(path) != expected:
            raise AssertionError(f"Cardboard import/UID lock drifted: {rel(path)}")


def validate_atlas() -> bytes:
    if sha256(FINAL_ATLAS) != APPROVED_CERTIFICATE_LOCKS["atlas_sha256"]:
        raise AssertionError("Approved cardboard atlas file SHA drifted")
    with Image.open(FINAL_ATLAS) as opened:
        atlas = opened.convert("RGBA")
    if atlas.size != (256, 96):
        raise AssertionError(f"Approved cardboard atlas size drifted: {atlas.size}")
    if rgba_sha256(atlas) != APPROVED_CERTIFICATE_LOCKS["atlas_rgba_sha256"]:
        raise AssertionError("Approved cardboard atlas decoded RGBA drifted")
    pixels = tuple(atlas.getdata())
    if any(pixel[3] not in (0, 255) for pixel in pixels):
        raise AssertionError("Approved cardboard atlas contains partial alpha")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError("Approved cardboard atlas contains dirty transparent RGB")
    return FINAL_ATLAS.read_bytes()


def validate_certificate_chain(
    report: dict[str, object],
    manifest: dict[str, object],
    stability: dict[str, object],
) -> bool:
    payloads = (report, manifest, stability)
    if manifest.get("stage") == APPROVED_STAGE:
        actual = {
            "builder_sha256": sha256(FINAL_BUILDER),
            "report_sha256": sha256(FINAL_REPORT),
            "manifest_sha256": sha256(FINAL_MANIFEST),
            "stability_sha256": sha256(FINAL_STABILITY),
            "atlas_sha256": sha256(FINAL_ATLAS),
        }
        for key, value in actual.items():
            if value != APPROVED_CERTIFICATE_LOCKS[key]:
                raise AssertionError(f"Approved cardboard certificate drifted: {key}")
        for payload in payloads:
            if (
                payload.get("stage") != APPROVED_STAGE
                or payload.get("approved_animation_selection") != APPROVED_SELECTION
                or payload.get("third_human_approved") is not True
                or payload.get("final_human_approved") is not True
                or payload.get("runtime_written") is not False
                or payload.get("runtime_paths_written") != []
            ):
                raise AssertionError("Approved cardboard certificate flags drifted")
        return False

    if report.get("stage") != INTEGRATED_STAGE or manifest.get("stage") != INTEGRATED_STAGE:
        raise AssertionError("Unexpected cardboard final/runtime certificate stage")
    if stability.get("stage") != APPROVED_STAGE or stability.get("runtime_written") is not False:
        raise AssertionError("Approved preview stability evidence drifted")
    for payload in (report, manifest):
        if (
            payload.get("approval_source_report_sha256")
            != APPROVED_CERTIFICATE_LOCKS["report_sha256"]
            or payload.get("approval_source_manifest_sha256")
            != APPROVED_CERTIFICATE_LOCKS["manifest_sha256"]
            or payload.get("approval_source_stability_sha256")
            != APPROVED_CERTIFICATE_LOCKS["stability_sha256"]
            or payload.get("runtime_written") is not True
            or payload.get("third_human_approved") is not True
            or payload.get("final_human_approved") is not True
        ):
            raise AssertionError("Integrated cardboard certificate flags drifted")
    return True


def animation_resource_text() -> str:
    lines = [
        '[gd_resource type="SpriteFrames" load_steps=26 format=3]',
        "",
        '[ext_resource type="Texture2D" path="res://resources/texture/enemy/artificial_creation/cardboard_monster.png" id="1_texture"]',
        "",
    ]
    subresource_ids: dict[tuple[str, int], str] = {}
    for animation, row, columns, _fps, _loop in ANIMATIONS:
        for local_index, column in enumerate(columns):
            subresource_id = f"AtlasTexture_{animation}_{local_index}"
            subresource_ids[(animation, local_index)] = subresource_id
            lines.extend([
                f'[sub_resource type="AtlasTexture" id="{subresource_id}"]',
                'atlas = ExtResource("1_texture")',
                f"region = Rect2({column * 32}, {row * 32}, 32, 32)",
                "filter_clip = true",
                "",
            ])
    animation_records: list[str] = []
    for animation, _row, columns, fps, loop in ANIMATIONS:
        frame_records = []
        for local_index, _column in enumerate(columns):
            frame_records.append(
                '{\n"duration": 1.0,\n"texture": SubResource("%s")\n}'
                % subresource_ids[(animation, local_index)]
            )
        animation_records.append(
            '{\n"frames": [%s],\n"loop": %s,\n"name": &"%s",\n"speed": %.1f\n}'
            % (", ".join(frame_records), str(loop).lower(), animation, fps)
        )
    lines.extend(["[resource]", "animations = [%s]" % ", ".join(animation_records), ""])
    rendered = "\n".join(lines)
    if rendered.count("filter_clip = true") != 24:
        raise AssertionError("Cardboard SpriteFrames filter_clip count drifted")
    return rendered


def publish_runtime_assets(atlas_bytes: bytes) -> dict[str, object]:
    for path in (RUNTIME_TEXTURE, RUNTIME_ANIMATION):
        assert_runtime_target(path)
        path.parent.mkdir(parents=True, exist_ok=True)
    if not RUNTIME_TEXTURE.is_file() or RUNTIME_TEXTURE.read_bytes() != atlas_bytes:
        RUNTIME_TEXTURE.write_bytes(atlas_bytes)
    if RUNTIME_TEXTURE.read_bytes() != atlas_bytes:
        raise AssertionError("Runtime cardboard texture is not byte-identical to the approved atlas")
    animation_text = animation_resource_text()
    if not RUNTIME_ANIMATION.is_file() or RUNTIME_ANIMATION.read_text(encoding="utf-8") != animation_text:
        RUNTIME_ANIMATION.write_text(animation_text, encoding="utf-8", newline="\n")
    animation_sha = sha256(RUNTIME_ANIMATION)
    return {
        "texture": {
            "path": rel(RUNTIME_TEXTURE),
            "source": rel(FINAL_ATLAS),
            "sha256": sha256(RUNTIME_TEXTURE),
            "byte_identical_to_approved_atlas": True,
            "size": [256, 96],
        },
        "animation": {
            "path": rel(RUNTIME_ANIMATION),
            "sha256": animation_sha,
            "atlas_texture_count": 24,
            "filter_clip_count": 24,
            "animations": {
                "move": {"frames": 8, "fps": 12.0, "loop": True, "row": 0},
                "windup": {"frames": 3, "fps": 9.0, "loop": False, "row": 1, "columns": [0, 1, 2]},
                "slash": {"frames": 5, "fps": 15.0, "loop": False, "row": 1, "columns": [3, 4, 5, 6, 7], "damage_frame_local_index": 1, "damage_frame_source_cell": {"row": 1, "column": 4}},
                "death": {"frames": 8, "fps": 12.0, "loop": False, "row": 2},
            },
        },
        "config_script": {"path": rel(CONFIG_SCRIPT), "sha256": CORE_FILE_LOCKS[CONFIG_SCRIPT]},
        "config": {"path": rel(CONFIG_RESOURCE), "sha256": CORE_FILE_LOCKS[CONFIG_RESOURCE]},
        "enemy_script": {"path": rel(ENEMY_SCRIPT), "sha256": CORE_FILE_LOCKS[ENEMY_SCRIPT]},
        "enemy_scene": {"path": rel(ENEMY_SCENE), "sha256": CORE_FILE_LOCKS[ENEMY_SCENE]},
        "capoo_knight_virtual_source": {"path": rel(CAPOO_KNIGHT_SCRIPT), "sha256": CORE_FILE_LOCKS[CAPOO_KNIGHT_SCRIPT]},
        "texture_import": {"path": rel(RUNTIME_TEXTURE_IMPORT), "sha256": IMPORT_UID_LOCKS[RUNTIME_TEXTURE_IMPORT], "uid": "uid://bk6bv3sf3ersw"},
        "config_script_uid": {"path": rel(CONFIG_SCRIPT_UID), "sha256": IMPORT_UID_LOCKS[CONFIG_SCRIPT_UID], "uid": "uid://breelwcx2ml6w"},
        "enemy_script_uid": {"path": rel(ENEMY_SCRIPT_UID), "sha256": IMPORT_UID_LOCKS[ENEMY_SCRIPT_UID], "uid": "uid://blqspia1h5c3v"},
    }


def update_runtime_certificates(
    report: dict[str, object],
    manifest: dict[str, object],
    runtime_assets: dict[str, object],
) -> None:
    runtime_paths = sorted(
        str(record["path"])
        for record in runtime_assets.values()
        if isinstance(record, dict) and "path" in record
    )
    integration = {
        "stage": INTEGRATED_STAGE,
        "preview_only": False,
        "third_human_approved": True,
        "final_human_approved": True,
        "runtime_written": True,
        "runtime_paths_written": runtime_paths,
        "approval_source_builder_sha256": APPROVED_CERTIFICATE_LOCKS["builder_sha256"],
        "approval_source_report_sha256": APPROVED_CERTIFICATE_LOCKS["report_sha256"],
        "approval_source_manifest_sha256": APPROVED_CERTIFICATE_LOCKS["manifest_sha256"],
        "approval_source_stability_sha256": APPROVED_CERTIFICATE_LOCKS["stability_sha256"],
        "runtime_assets": runtime_assets,
    }
    report.update(integration)
    write_json(FINAL_REPORT, report)
    integration["report"] = {"path": rel(FINAL_REPORT), "sha256": sha256(FINAL_REPORT)}
    manifest.update(integration)
    write_json(FINAL_MANIFEST, manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--publish",
        action="store_true",
        help="Publish the locked, human-approved final candidate into runtime resources.",
    )
    args = parser.parse_args()
    if not args.publish:
        raise SystemExit("Refusing runtime publication without --publish")

    validate_core_files()
    atlas_bytes = validate_atlas()
    report = load_json(FINAL_REPORT)
    manifest = load_json(FINAL_MANIFEST)
    stability = load_json(FINAL_STABILITY)
    already_integrated = validate_certificate_chain(report, manifest, stability)
    runtime_assets = publish_runtime_assets(atlas_bytes)
    if already_integrated:
        previous_assets = manifest.get("runtime_assets")
        if not isinstance(previous_assets, dict):
            raise AssertionError("Integrated cardboard runtime asset certificate is missing")
        for key, previous_record in previous_assets.items():
            if key not in runtime_assets or runtime_assets[key] != previous_record:
                raise AssertionError(f"Integrated cardboard runtime asset certificate drifted: {key}")
    update_runtime_certificates(report, manifest, runtime_assets)
    print(
        "CARDBOARD_MONSTER_RUNTIME_ASSETS_OK "
        f"texture={sha256(RUNTIME_TEXTURE)} animation={sha256(RUNTIME_ANIMATION)} "
        f"report={sha256(FINAL_REPORT)} manifest={sha256(FINAL_MANIFEST)}"
    )


if __name__ == "__main__":
    main()
