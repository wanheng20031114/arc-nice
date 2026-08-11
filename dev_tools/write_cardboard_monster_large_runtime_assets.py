#!/usr/bin/env python3
"""Publish the approved large-cardboard atlas and runtime SpriteFrames."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

from enemy_asset_report_paths import enemy_asset_report_path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/cardboard_monster_large"
FINAL_ATLAS = SOURCE_DIR / "cardboard_monster_large_final_candidate_atlas.png"
FINAL_REPORT = enemy_asset_report_path("cardboard_monster_large_final_candidate_report.json")
FINAL_MANIFEST = enemy_asset_report_path("cardboard_monster_large_final_candidate_manifest.json")
FINAL_STABILITY = enemy_asset_report_path("cardboard_monster_large_final_candidate_stability.json")
FINAL_BUILDER = ROOT / "dev_tools/build_cardboard_monster_large_final_preview.py"

RUNTIME_TEXTURE = ROOT / "resources/texture/enemy/artificial_creation/cardboard_monster_large.png"
RUNTIME_TEXTURE_IMPORT = Path(str(RUNTIME_TEXTURE) + ".import")
RUNTIME_ANIMATION = ROOT / "resources/animation/cardboard_monster_large.tres"
CONFIG_SCRIPT = ROOT / "resources/config/enemies/cardboard_monster_large_config.gd"
CONFIG_SCRIPT_UID = Path(str(CONFIG_SCRIPT) + ".uid")
CONFIG_RESOURCE = ROOT / "resources/config/enemies/cardboard_monster_large.tres"
ENEMY_SCRIPT = ROOT / "scene/enemy/artificial_creation/cardboard_monster_large.gd"
ENEMY_SCRIPT_UID = Path(str(ENEMY_SCRIPT) + ".uid")
ENEMY_SCENE = ROOT / "scene/enemy/artificial_creation/cardboard_monster_large.tscn"

BASE_CONFIG_SCRIPT = ROOT / "resources/config/enemies/cardboard_monster_config.gd"
BASE_ENEMY_SCRIPT = ROOT / "scene/enemy/artificial_creation/cardboard_monster.gd"
CAPOO_KNIGHT_SCRIPT = ROOT / "scene/enemy/capoo/capoo_knight.gd"
DAMAGE_TARGET_PROFILE = ROOT / "scene/combat/damage_target_profile.gd"
DEFAULT_DROP_TABLE = ROOT / "resources/config/enemies/default_enemy_drop_table.tres"

APPROVED_STAGE = "final_candidate_third_human_gate_approved"
INTEGRATED_STAGE = "final_candidate_approved_runtime_written"
APPROVED_SELECTION = {"move": "m1", "attack": "a1", "death": "d2"}
APPROVED_CERTIFICATE_LOCKS = {
    "builder_sha256": "ecfe961bde382480c197c48fc031e82368e0566b9f7901f08e699edf4f044ed7",
    "report_sha256": "1e2edbaf05a47783d0b3fdb6572568a9c3ee472664a6d7af984542acacedc207",
    "manifest_sha256": "c67b3b987f2beeb64d74f3791940ca2a09f23cb41af6f0a9249958c4fec02313",
    "stability_sha256": "dfffa6e51cb8b2c1cbcca5ea099b44f6f6f51307357744fce2685373057ad0da",
    "atlas_sha256": "0c883183710140c2923877447db46f14c19c19ce61b7c92f388e3574f2f161e6",
    "atlas_rgba_sha256": "c15ce57637c39800d78024404d1a9a093fd9b48194f17fa1b65b9d451f561999",
}
CORE_FILE_LOCKS = {
    CONFIG_SCRIPT: "50e9c24ce1ff60ac451a90d92ede8e98946b71a3b8f7ad3098f669010ff4a15d",
    CONFIG_RESOURCE: "d864bb0234f015cc603f6427428e83b0d37f823193a32a6f049959c5c2b3de66",
    ENEMY_SCRIPT: "d2313813924d174253214d3219bbe63c451ea6459e98e8d46c2902aa60fc309b",
    ENEMY_SCENE: "9eb9145e1686322abc826f6e0f075c6ee70929e3acacc2351af00d52311ceb77",
    BASE_CONFIG_SCRIPT: "9692b9e6a4e31da27811dbb6cc3fef935cca86bd6917e1cade27cbf91c87ed3b",
    BASE_ENEMY_SCRIPT: "9daafe935e569bdbeb8194a2e9d99fd1c72de756b7d7b2f3296ec951a57dd723",
    CAPOO_KNIGHT_SCRIPT: "2db55139d5686fd11c18e73094b82a65850d29481003962fe38030fef3583773",
    DAMAGE_TARGET_PROFILE: "d80de1ef4ec960219eaeb2e60fb1b55b8f37a985822464f91e8ca78bae7e978a",
    DEFAULT_DROP_TABLE: "2fbd4d2b579309c927cd71d026eab6d433db753e1df939999bccc0973c7b2791",
}

IMPORT_UID_LOCKS = {
    RUNTIME_TEXTURE_IMPORT: "2120213b2788edaba663c068ba6757f3ec32ce4e77969547dadbc447ec5928be",
    CONFIG_SCRIPT_UID: "52a955238fecdf9501b49c4f265d986125e302f0ba3b2f96715a63da04dc7f93",
    ENEMY_SCRIPT_UID: "4a6a8118310f98515b5a472d457b7ececfa8c2a684613b27ee072f608df66387",
}

ANIMATIONS = (
    ("move", 0, tuple(range(8)), 9.0, True),
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
    if not any(base.resolve() in resolved.parents for base in (ROOT / "resources", ROOT / "scene")):
        raise AssertionError(f"Runtime target escaped resources/scene: {path}")


def validate_core_files() -> None:
    for path, expected in CORE_FILE_LOCKS.items():
        if not path.is_file() or sha256(path) != expected:
            raise AssertionError(f"Large-cardboard core lock drifted: {rel(path)}")
    if "extends CardboardMonsterConfig" not in CONFIG_SCRIPT.read_text(encoding="utf-8"):
        raise AssertionError("Large config lost CardboardMonsterConfig inheritance")
    enemy_source = ENEMY_SCRIPT.read_text(encoding="utf-8")
    if "extends CardboardMonster" not in enemy_source or "cardboard_monster_large_slash" not in enemy_source:
        raise AssertionError("Large enemy inheritance/source contract drifted")
    profile_source = DAMAGE_TARGET_PROFILE.read_text(encoding="utf-8")
    if "var fixed_damage_per_accepted_hit: float = 0.0" not in profile_source:
        raise AssertionError("DamageTargetProfile fixed-hit API is unavailable")


def validate_import_uid_files() -> None:
    required = {RUNTIME_TEXTURE_IMPORT, CONFIG_SCRIPT_UID, ENEMY_SCRIPT_UID}
    if set(IMPORT_UID_LOCKS) != required:
        raise AssertionError(
            "Import/UID locks are not frozen; run --stage-import, import with Godot, then freeze them"
        )
    for path, expected in IMPORT_UID_LOCKS.items():
        if not path.is_file() or sha256(path) != expected:
            raise AssertionError(f"Large-cardboard import/UID lock drifted: {rel(path)}")


def validate_atlas() -> bytes:
    if sha256(FINAL_ATLAS) != APPROVED_CERTIFICATE_LOCKS["atlas_sha256"]:
        raise AssertionError("Approved large-cardboard atlas file SHA drifted")
    with Image.open(FINAL_ATLAS) as opened:
        atlas = opened.convert("RGBA")
    if atlas.size != (384, 144):
        raise AssertionError(f"Approved large-cardboard atlas size drifted: {atlas.size}")
    if rgba_sha256(atlas) != APPROVED_CERTIFICATE_LOCKS["atlas_rgba_sha256"]:
        raise AssertionError("Approved large-cardboard atlas decoded RGBA drifted")
    pixels = tuple(atlas.getdata())
    if any(pixel[3] not in (0, 255) for pixel in pixels):
        raise AssertionError("Approved large-cardboard atlas contains partial alpha")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError("Approved large-cardboard atlas contains dirty transparent RGB")
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
                raise AssertionError(f"Approved large-cardboard certificate drifted: {key}")
        for payload in payloads:
            if (
                payload.get("stage") != APPROVED_STAGE
                or payload.get("approved_animation_selection") != APPROVED_SELECTION
                or payload.get("third_human_approved") is not True
                or payload.get("final_human_approved") is not True
                or payload.get("runtime_written") is not False
                or payload.get("runtime_paths_written") != []
                or payload.get("p1c_written") is not False
                or payload.get("protocol_written") is not False
            ):
                raise AssertionError("Approved large-cardboard certificate flags drifted")
        return False

    if report.get("stage") != INTEGRATED_STAGE or manifest.get("stage") != INTEGRATED_STAGE:
        raise AssertionError("Unexpected large-cardboard runtime certificate stage")
    if stability.get("stage") != APPROVED_STAGE or stability.get("runtime_written") is not False:
        raise AssertionError("Approved preview stability evidence drifted")
    for payload in (report, manifest):
        if (
            payload.get("approval_source_report_sha256") != APPROVED_CERTIFICATE_LOCKS["report_sha256"]
            or payload.get("approval_source_manifest_sha256") != APPROVED_CERTIFICATE_LOCKS["manifest_sha256"]
            or payload.get("approval_source_stability_sha256") != APPROVED_CERTIFICATE_LOCKS["stability_sha256"]
            or payload.get("runtime_written") is not True
            or payload.get("third_human_approved") is not True
            or payload.get("final_human_approved") is not True
            or payload.get("p1c_written") is not False
            or payload.get("protocol_written") is not False
        ):
            raise AssertionError("Integrated large-cardboard certificate flags drifted")
    return True


def animation_resource_text() -> str:
    lines = [
        '[gd_resource type="SpriteFrames" load_steps=26 format=3]',
        "",
        '[ext_resource type="Texture2D" path="res://resources/texture/enemy/artificial_creation/cardboard_monster_large.png" id="1_texture"]',
        "",
    ]
    subresource_ids: dict[tuple[str, int], str] = {}
    for animation, row, columns, _fps, _loop in ANIMATIONS:
        for local_index, column in enumerate(columns):
            subresource_id = f"AtlasTexture_{animation}_{local_index}"
            subresource_ids[(animation, local_index)] = subresource_id
            lines.extend(
                [
                    f'[sub_resource type="AtlasTexture" id="{subresource_id}"]',
                    'atlas = ExtResource("1_texture")',
                    f"region = Rect2({column * 48}, {row * 48}, 48, 48)",
                    "filter_clip = true",
                    "",
                ]
            )
    animation_records: list[str] = []
    for animation, _row, columns, fps, loop in ANIMATIONS:
        frame_records = [
            '{\n"duration": 1.0,\n"texture": SubResource("%s")\n}'
            % subresource_ids[(animation, local_index)]
            for local_index, _column in enumerate(columns)
        ]
        animation_records.append(
            '{\n"frames": [%s],\n"loop": %s,\n"name": &"%s",\n"speed": %.1f\n}'
            % (", ".join(frame_records), str(loop).lower(), animation, fps)
        )
    lines.extend(["[resource]", "animations = [%s]" % ", ".join(animation_records), ""])
    rendered = "\n".join(lines)
    if rendered.count("filter_clip = true") != 24:
        raise AssertionError("Large-cardboard SpriteFrames filter_clip count drifted")
    return rendered


def publish_texture_and_animation(atlas_bytes: bytes) -> None:
    for path in (RUNTIME_TEXTURE, RUNTIME_ANIMATION):
        assert_runtime_target(path)
        path.parent.mkdir(parents=True, exist_ok=True)
    if not RUNTIME_TEXTURE.is_file() or RUNTIME_TEXTURE.read_bytes() != atlas_bytes:
        RUNTIME_TEXTURE.write_bytes(atlas_bytes)
    if RUNTIME_TEXTURE.read_bytes() != atlas_bytes:
        raise AssertionError("Runtime texture is not byte-identical to the approved atlas")
    animation_text = animation_resource_text()
    if not RUNTIME_ANIMATION.is_file() or RUNTIME_ANIMATION.read_text(encoding="utf-8") != animation_text:
        RUNTIME_ANIMATION.write_text(animation_text, encoding="utf-8", newline="\n")


def runtime_asset_records() -> dict[str, object]:
    import_text = RUNTIME_TEXTURE_IMPORT.read_text(encoding="utf-8")
    import_uid_line = next(
        (line for line in import_text.splitlines() if line.startswith("uid=")),
        None,
    )
    if import_uid_line is None:
        raise AssertionError("Large-cardboard texture import lost its UID")
    records: dict[str, object] = {
        "texture": {
            "path": rel(RUNTIME_TEXTURE),
            "source": rel(FINAL_ATLAS),
            "sha256": sha256(RUNTIME_TEXTURE),
            "byte_identical_to_approved_atlas": True,
            "size": [384, 144],
        },
        "animation": {
            "path": rel(RUNTIME_ANIMATION),
            "sha256": sha256(RUNTIME_ANIMATION),
            "atlas_texture_count": 24,
            "filter_clip_count": 24,
            "animations": {
                "move": {"frames": 8, "fps": 9.0, "loop": True, "row": 0},
                "windup": {"frames": 3, "fps": 9.0, "loop": False, "row": 1, "columns": [0, 1, 2]},
                "slash": {
                    "frames": 5,
                    "fps": 15.0,
                    "loop": False,
                    "row": 1,
                    "columns": [3, 4, 5, 6, 7],
                    "damage_frame_local_index": 1,
                    "damage_frame_source_cell": {"row": 1, "column": 4},
                },
                "death": {"frames": 8, "fps": 12.0, "loop": False, "row": 2},
            },
        },
        "config_script": {"path": rel(CONFIG_SCRIPT), "sha256": CORE_FILE_LOCKS[CONFIG_SCRIPT]},
        "config": {"path": rel(CONFIG_RESOURCE), "sha256": CORE_FILE_LOCKS[CONFIG_RESOURCE]},
        "enemy_script": {"path": rel(ENEMY_SCRIPT), "sha256": CORE_FILE_LOCKS[ENEMY_SCRIPT]},
        "enemy_scene": {"path": rel(ENEMY_SCENE), "sha256": CORE_FILE_LOCKS[ENEMY_SCENE]},
        "texture_import": {
            "path": rel(RUNTIME_TEXTURE_IMPORT),
            "sha256": IMPORT_UID_LOCKS[RUNTIME_TEXTURE_IMPORT],
            "uid_line": import_uid_line,
        },
        "config_script_uid": {
            "path": rel(CONFIG_SCRIPT_UID),
            "sha256": IMPORT_UID_LOCKS[CONFIG_SCRIPT_UID],
            "uid": CONFIG_SCRIPT_UID.read_text(encoding="utf-8").strip(),
        },
        "enemy_script_uid": {
            "path": rel(ENEMY_SCRIPT_UID),
            "sha256": IMPORT_UID_LOCKS[ENEMY_SCRIPT_UID],
            "uid": ENEMY_SCRIPT_UID.read_text(encoding="utf-8").strip(),
        },
    }
    return records


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
        "p1c_written": False,
        "protocol_written": False,
        "approval_source_builder_sha256": APPROVED_CERTIFICATE_LOCKS["builder_sha256"],
        "approval_source_report_sha256": APPROVED_CERTIFICATE_LOCKS["report_sha256"],
        "approval_source_manifest_sha256": APPROVED_CERTIFICATE_LOCKS["manifest_sha256"],
        "approval_source_stability_sha256": APPROVED_CERTIFICATE_LOCKS["stability_sha256"],
        "runtime_writer": {"path": rel(Path(__file__).resolve()), "sha256": sha256(Path(__file__).resolve())},
        "runtime_assets": runtime_assets,
    }
    report.update(integration)
    write_json(FINAL_REPORT, report)
    integration["report"] = {"path": rel(FINAL_REPORT), "sha256": sha256(FINAL_REPORT)}
    manifest.update(integration)
    write_json(FINAL_MANIFEST, manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--stage-import",
        action="store_true",
        help="Publish only the locked texture/SpriteFrames so Godot can generate unique import UIDs.",
    )
    mode.add_argument(
        "--publish",
        action="store_true",
        help="Publish and certify the locked, human-approved runtime assets.",
    )
    args = parser.parse_args()

    validate_core_files()
    atlas_bytes = validate_atlas()
    report = load_json(FINAL_REPORT)
    manifest = load_json(FINAL_MANIFEST)
    stability = load_json(FINAL_STABILITY)
    already_integrated = validate_certificate_chain(report, manifest, stability)
    if args.stage_import:
        if already_integrated:
            raise AssertionError("Import staging is not allowed after runtime integration")
        publish_texture_and_animation(atlas_bytes)
        print(
            "CARDBOARD_MONSTER_LARGE_IMPORT_STAGE_OK "
            f"texture={sha256(RUNTIME_TEXTURE)} animation={sha256(RUNTIME_ANIMATION)}"
        )
        return

    validate_import_uid_files()
    publish_texture_and_animation(atlas_bytes)
    runtime_assets = runtime_asset_records()
    if already_integrated:
        previous_assets = manifest.get("runtime_assets")
        if not isinstance(previous_assets, dict) or previous_assets != runtime_assets:
            raise AssertionError("Integrated large-cardboard runtime asset certificate drifted")
    update_runtime_certificates(report, manifest, runtime_assets)
    print(
        "CARDBOARD_MONSTER_LARGE_RUNTIME_ASSETS_OK "
        f"texture={sha256(RUNTIME_TEXTURE)} animation={sha256(RUNTIME_ANIMATION)} "
        f"report={sha256(FINAL_REPORT)} manifest={sha256(FINAL_MANIFEST)}"
    )


if __name__ == "__main__":
    main()
