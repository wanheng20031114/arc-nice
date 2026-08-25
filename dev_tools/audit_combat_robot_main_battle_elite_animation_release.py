#!/usr/bin/env python3
"""Certify the approved high-resolution runtime animation release.

This tool never creates a sprite frame, atlas, preview, or runtime resource.  It
only hashes the seven user-approved raw ImageGen sheets and checks the two
pixel-pipeline admission modes: direct native and exact integer display.  A
failed native-grid audit remains a failed native-grid audit; it does not block
the separately authorized source-preserved high-resolution runtime branch.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev_assets/source_images/combat_robot_main_battle_elite"
REPORT_DIR = ROOT / "dev_tools/output/asset_reports"
APPROVAL = SOURCE / "combat_robot_main_battle_elite_animation_selection.json"
REPORT = REPORT_DIR / "combat_robot_main_battle_elite_animation_native_eligibility_report.json"
STABILITY = REPORT_DIR / "combat_robot_main_battle_elite_animation_native_eligibility_stability.json"
LEGACY_INVALID = REPORT_DIR / "combat_robot_main_battle_elite_legacy_animation_materials_invalid.json"
PIXEL_GRID_ANALYZER = ROOT / "dev_tools/pixel_grid_analyzer.py"
PIXEL_GRID_ANALYZER_SHA256 = "504ad297311e67d001aee99d73f8c939372b7e83695a909c5c0a72a9c132e3b5"

STAGE = "high_resolution_runtime_released_native64_ineligible"
TARGET_FRAME = [64, 64]
TARGET_ATLAS = [512, 448]
RUNTIME_STRATEGY = "high_resolution_source_preserved_linear_display"
RUNTIME_SCALE = 0.125
RUNTIME_FILTER = "linear"
RUNTIME_PATHS = {
    "texture": ROOT / "resources/texture/enemy/mechanical_life/combat_robot_main_battle_elite.png",
    "animation": ROOT / "resources/animation/combat_robot_main_battle_elite.tres",
}
RUNTIME_SUPPORT_PATHS = {
    "scene": ROOT / "scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn",
    "texture_import": ROOT / "resources/texture/enemy/mechanical_life/combat_robot_main_battle_elite.png.import",
    "config": ROOT / "resources/config/enemies/combat_robot_main_battle_elite.tres",
}
RUNTIME_BUILD_REPORT = REPORT_DIR / "combat_robot_main_battle_elite_highres_runtime_build_report.json"
RUNTIME_BUILDER = ROOT / "dev_tools/build_combat_robot_main_battle_elite_highres_runtime_assets.py"
ALLOWED_RUNTIME_BUILD_OPERATIONS = [
    "native_alpha_validation",
    "crop",
    "integer_translate",
    "pad",
]
EXPECTED_REPORTED_SPATIAL_OPERATIONS = [
    "native_alpha_validation",
    "audited_source_crop_or_component_extraction",
    "integer_translation",
    "transparent_padding",
    "tight_atlas_packing_with_atlastexture_margin",
]

IDENTITY_ANCHOR = SOURCE / "combat_robot_main_battle_elite_user_approved_main_visual_20260812.png"
IDENTITY_ANCHOR_SHA256 = "9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7"


SHEETS: dict[str, dict[str, Any]] = {
    "m1": {
        "motion": "M1 重踏换脚",
        "path": SOURCE / "combat_robot_main_battle_elite_animation_m1_user_anchor_only_v5_upper_body_y_targeted_regen_imagegen.png",
        "sha256": "cae3be91dec538c919c7337eeb53f189316592891c084cf90f911ecdd7301942",
        "prompt": SOURCE / "combat_robot_main_battle_elite_animation_m1_user_anchor_only_v4_v5_upper_body_y_lineage.md",
        "layout": [4, 2],
        "frames": 8,
        "grid_analyzer_confidence": 0.247,
    },
    "n2": {
        "motion": "N2 并行重压",
        "path": SOURCE / "combat_robot_main_battle_elite_animation_n2_parallel_heavy_press_anchor_only_v3_independent_imagegen.png",
        "sha256": "7cb231104872f4e8b6079733faab764094665ca725cdd8902badb780d4e8e68f",
        "prompt": SOURCE / "combat_robot_main_battle_elite_animation_n2_parallel_heavy_press_anchor_only_v3_independent_prompt.md",
        "layout": [4, 2],
        "frames": 8,
        "grid_analyzer_confidence": 0.074,
    },
    "c2_windup_dash": {
        "motion": "C2 交叉护胸前摇与冲锋",
        "path": SOURCE / "combat_robot_main_battle_elite_anim_c2_windup_dash_user_anchor_only_v1_imagegen.png",
        "sha256": "02a9008d3acbc04fe5eb37f08d13d55fe4419a6febe8183a17f1d1a2f3b90250",
        "prompt": SOURCE / "combat_robot_main_battle_elite_anim_c2_windup_dash_user_anchor_only_v1_prompt.md",
        "layout": [4, 2],
        "frames": 8,
        "grid_analyzer_confidence": 0.026,
    },
    "c2_circle_slash": {
        "motion": "C2 开花圆斩",
        "path": SOURCE / "combat_robot_main_battle_elite_anim_c2_circle_slash_user_anchor_only_v1_imagegen.png",
        "sha256": "b97cbc83d003d24f3971517153fae7ef63449a17c4eaec7d415a39b17863d450",
        "prompt": SOURCE / "combat_robot_main_battle_elite_anim_c2_circle_slash_user_anchor_only_v1_prompt.md",
        "layout": [4, 2],
        "frames": 8,
        "grid_analyzer_confidence": 0.017,
    },
    "j1_takeoff": {
        "motion": "J1 收膝弹射起跳",
        "path": SOURCE / "combat_robot_main_battle_elite_anim_j1_takeoff_user_anchor_only_v1_imagegen.png",
        "sha256": "9ad07d220650c5a85f6c05f3561469cbef9bc6fbeaa943a11c88113d8788800e",
        "prompt": SOURCE / "combat_robot_main_battle_elite_anim_j1_takeoff_user_anchor_only_v1_prompt.md",
        "layout": [5, 1],
        "frames": 5,
        "grid_analyzer_confidence": 0.021,
    },
    "j1_drop_slash": {
        "motion": "J1 落地瞬间双剑对称挥斩",
        "path": SOURCE / "combat_robot_main_battle_elite_anim_j1_drop_bilateral_slash_user_anchor_only_v6_independent_imagegen.png",
        "sha256": "bc4d1b46132a2f3ba54de24f71698e3334daf919231a820cd94d005e7e011371",
        "prompt": SOURCE / "combat_robot_main_battle_elite_anim_j1_drop_bilateral_slash_user_anchor_only_v6_independent_prompt.md",
        "layout": [4, 2],
        "frames": 8,
        "grid_analyzer_confidence": 0.020,
    },
    "d1": {
        "motion": "D1 熄灭跪倒解体",
        "path": SOURCE / "death_animation_drafts/combat_robot_main_battle_elite_death_d1_user_anchor_only_v1_imagegen.png",
        "sha256": "a3b13792973dd7faabffbb82f5aed8411542af43a0de446e8004114184465754",
        "prompt": SOURCE / "death_animation_drafts/combat_robot_main_battle_elite_death_d1_user_anchor_only_v1_prompt.md",
        "layout": [4, 2],
        "frames": 8,
        "grid_analyzer_confidence": 0.020,
    },
}


REVIEW_GIFS = {
    "m1": {
        "path": ROOT / "dev_assets/generated_previews/combat_robot_main_battle_elite_anchor_only_review_gifs/combat_robot_main_battle_elite_m1_review.gif",
        "sha256": "85801f87258897d1d6cca760663f1c0a673bcd0a9268edfe3e9e832d875d3eb2",
        "durations_ms": [130] * 8,
    },
    "n2": {
        "path": ROOT / "dev_assets/generated_previews/combat_robot_main_battle_elite_anchor_only_review_gifs/combat_robot_main_battle_elite_n2_review.gif",
        "sha256": "933f664ea6b4c5f1e90917b7d4e1d02f0b7e6326d1354c0a071383118cbecd9d",
        "durations_ms": [140, 140, 180, 80, 80, 100, 120, 260],
    },
    "c2": {
        "path": ROOT / "dev_assets/generated_previews/combat_robot_main_battle_elite_anchor_only_review_gifs/combat_robot_main_battle_elite_c2_review.gif",
        "sha256": "fbabf33428c5fb71b2be59bfb3c36055b1de716e2b4963df03ae364c3d5e3d1f",
        "durations_ms": [140] * 4 + [60] * 4 + [80] * 7 + [220],
    },
    "j1": {
        "path": ROOT / "dev_assets/generated_previews/combat_robot_main_battle_elite_anchor_only_review_gifs/combat_robot_main_battle_elite_j1_review.gif",
        "sha256": "ddba4ce4eb1d73640a6272cf2ca1f8173c235f6a55c0af70d9be2d00d92b2d83",
        "durations_ms": [120, 100, 80, 70, 90] + [60] * 3 + [90] * 4 + [220],
    },
    "d1": {
        "path": ROOT / "dev_assets/generated_previews/combat_robot_main_battle_elite_anchor_only_review_gifs/combat_robot_main_battle_elite_d1_review.gif",
        "sha256": "9da022c14405b4d2d8534662656c8b059701585cb6f08a40178aabbf6cfda19a",
        "durations_ms": [120] * 7 + [360],
    },
}


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_json(payload: Any) -> bytes:
    return (json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def transition_phase_gcd(array: np.ndarray, axis: int) -> tuple[int, int]:
    """Return (unique transition coordinates, gcd of coordinate differences)."""
    if axis == 0:
        changed = array[:, 1:] != array[:, :-1]
        if array.ndim == 3:
            changed = np.any(changed, axis=2)
        coordinates = np.unique(np.where(changed)[1] + 1)
    else:
        changed = array[1:] != array[:-1]
        if array.ndim == 3:
            changed = np.any(changed, axis=2)
        coordinates = np.unique(np.where(changed)[0] + 1)
    if len(coordinates) < 2:
        return int(len(coordinates)), 0
    result = 0
    origin = int(coordinates[0])
    for coordinate in coordinates[1:]:
        result = math.gcd(result, int(coordinate) - origin)
        if result == 1:
            break
    return int(len(coordinates)), result


def audit_sheet(key: str, spec: dict[str, Any]) -> dict[str, Any]:
    path: Path = spec["path"]
    prompt: Path = spec["prompt"]
    if not path.is_file() or sha256_file(path) != spec["sha256"]:
        raise AssertionError(f"approved raw source missing or drifted: {key}")
    if not prompt.is_file():
        raise AssertionError(f"generation record missing: {key}")
    image = Image.open(path).convert("RGBA")
    rgba = np.asarray(image, dtype=np.uint8)
    if rgba[..., 3].min() == 255:
        raise AssertionError(f"approved source lacks native transparent Alpha: {key}")
    alpha = (rgba[..., 3] > 0).astype(np.uint8)
    raw_x_count, raw_x_gcd = transition_phase_gcd(rgba, 0)
    raw_y_count, raw_y_gcd = transition_phase_gcd(rgba, 1)
    alpha_x_count, alpha_x_gcd = transition_phase_gcd(alpha, 0)
    alpha_y_count, alpha_y_gcd = transition_phase_gcd(alpha, 1)
    max_alpha_scale = math.gcd(alpha_x_gcd, alpha_y_gcd)
    return {
        "motion": spec["motion"],
        "path": rel(path),
        "file_sha256": spec["sha256"],
        "decoded_rgba_sha256": sha256_bytes(rgba.tobytes()),
        "decoded_size": list(image.size),
        "decoded_mode": "RGBA",
        "declared_layout": spec["layout"],
        "declared_frame_count": spec["frames"],
        "generation_record": {"path": rel(prompt), "sha256": sha256_file(prompt)},
        "project_pixel_grid_analyzer_diagnostic": {
            "tool_path": rel(PIXEL_GRID_ANALYZER),
            "tool_sha256": PIXEL_GRID_ANALYZER_SHA256,
            "detection_mode": "native_or_unknown",
            "grid_cell_width": 1.0,
            "grid_cell_height": 1.0,
            "confidence": spec["grid_analyzer_confidence"],
            "admission_evidence": False,
        },
        "direct_native": {
            "eligible": False,
            "target_frame_size": TARGET_FRAME,
            "reason": "raw input is a large multi-frame ImageGen review sheet, not direct 64x64 frame data; no zero-resampling direct-native lineage exists",
        },
        "exact_integer_display": {
            "eligible": False,
            "raw_rgba_transition_coordinates": {"x": raw_x_count, "y": raw_y_count},
            "raw_rgba_transition_phase_gcd": {"x": raw_x_gcd, "y": raw_y_gcd},
            "source_alpha_transition_coordinates": {"x": alpha_x_count, "y": alpha_y_count},
            "source_alpha_transition_phase_gcd": {"x": alpha_x_gcd, "y": alpha_y_gcd},
            "max_common_square_integer_scale_from_immutable_alpha": max_alpha_scale,
            "shared_frame_canvas_origin_certificate": None,
            "shared_grid_phase_certificate": None,
            "mixed_cell_certificate": None,
            "positive_evidence": False,
            "reason": "immutable foreground/background transitions have phase gcd 1 on both axes, so no scale >1 is possible without per-frame phase fitting or many-to-one sampling",
        },
    }


def runtime_artifact_record() -> dict[str, Any]:
    artifacts: dict[str, Any] = {}
    for role, path in RUNTIME_PATHS.items():
        if not path.is_file():
            raise AssertionError(f"authorized runtime artifact missing: {role}: {rel(path)}")
        artifacts[role] = {
            "path": rel(path),
            "sha256": sha256_file(path),
            "byte_size": path.stat().st_size,
        }
    support_artifacts: dict[str, Any] = {}
    for role, path in RUNTIME_SUPPORT_PATHS.items():
        if not path.is_file():
            raise AssertionError(f"runtime support artifact missing: {role}: {rel(path)}")
        support_artifacts[role] = {
            "path": rel(path),
            "sha256": sha256_file(path),
            "byte_size": path.stat().st_size,
        }
    scene_text = RUNTIME_SUPPORT_PATHS["scene"].read_text(encoding="utf-8")
    import_text = RUNTIME_SUPPORT_PATHS["texture_import"].read_text(encoding="utf-8")
    if not all(
        marker in scene_text
        for marker in (
            'metadata/runtime_visual_strategy = "high_resolution_source_preserved_linear_display"',
            "metadata/runtime_visual_native64_eligible = false",
            "texture_filter = 2",
            "scale = Vector2(0.125, 0.125)",
            'sprite_frames = ExtResource("3_frames")',
        )
    ):
        raise AssertionError("runtime scene display contract mismatch")
    animated_sprite_block = scene_text.split(
        '[node name="AnimatedSprite2D" parent="." index="0"]', 1
    )[-1].split("\n[node ", 1)[0]
    if "visible = false" in animated_sprite_block or "runtime_visual_release_blocked" in scene_text:
        raise AssertionError("runtime scene still carries a visual release block")
    if not all(
        marker in import_text
        for marker in (
            "compress/mode=0",
            "mipmaps/generate=false",
            "process/size_limit=0",
        )
    ):
        raise AssertionError("runtime texture import contract mismatch")
    if not RUNTIME_BUILD_REPORT.is_file():
        raise AssertionError(f"runtime build report missing: {rel(RUNTIME_BUILD_REPORT)}")
    build_report = json.loads(RUNTIME_BUILD_REPORT.read_text(encoding="utf-8"))
    if (
        build_report.get("stage") != "high_resolution_source_preserved_runtime_assets_built"
        or build_report.get("runtime_strategy") != RUNTIME_STRATEGY
        or build_report.get("native64_eligible") is not False
        or build_report.get("native64_claimed") is not False
        or build_report.get("runtime_written") is not True
        or build_report.get("runtime_scale") != [RUNTIME_SCALE, RUNTIME_SCALE]
        or build_report.get("runtime_texture_filter") != RUNTIME_FILTER
        or build_report.get("source_pixel_scale") != [1, 1]
    ):
        raise AssertionError("runtime build report strategy contract mismatch")
    if build_report.get("spatial_operations") != EXPECTED_REPORTED_SPATIAL_OPERATIONS:
        raise AssertionError("runtime build report spatial operation contract mismatch")
    runtime_builder = build_report.get("runtime_builder", {})
    if (
        not RUNTIME_BUILDER.is_file()
        or runtime_builder.get("path") != rel(RUNTIME_BUILDER)
        or runtime_builder.get("sha256") != sha256_file(RUNTIME_BUILDER)
    ):
        raise AssertionError("runtime builder missing or drifted")
    conservation = build_report.get("foreground_conservation", {})
    if (
        conservation.get("lost") != 0
        or conservation.get("duplicated") != 0
        or conservation.get("accepted_source_total") != conservation.get("runtime_total")
    ):
        raise AssertionError("runtime foreground conservation failed")
    for role, artifact in artifacts.items():
        report_artifact = build_report.get("artifacts", {}).get(role, {})
        if report_artifact.get("path") != artifact["path"] or report_artifact.get("sha256") != artifact["sha256"]:
            raise AssertionError(f"runtime build report artifact drift: {role}")
    return {
        "authorized": True,
        "released": True,
        "strategy": RUNTIME_STRATEGY,
        "source_representation": "approved_high_resolution_frames_preserved_without_spatial_resampling",
        "review_gifs_used_as_runtime_source": False,
        "allowed_asset_build_operations": ALLOWED_RUNTIME_BUILD_OPERATIONS,
        "reported_spatial_operations": EXPECTED_REPORTED_SPATIAL_OPERATIONS,
        "spatial_resampling_during_asset_build": False,
        "runtime_display": {
            "uniform_scale": RUNTIME_SCALE,
            "texture_filter": RUNTIME_FILTER,
            "mipmaps": False,
        },
        "artifacts": artifacts,
        "support_artifacts": support_artifacts,
        "build_report": {
            "path": rel(RUNTIME_BUILD_REPORT),
            "sha256": sha256_file(RUNTIME_BUILD_REPORT),
        },
        "runtime_builder": {
            "path": rel(RUNTIME_BUILDER),
            "sha256": sha256_file(RUNTIME_BUILDER),
        },
    }


def build_audit() -> dict[str, Any]:
    if not IDENTITY_ANCHOR.is_file() or sha256_file(IDENTITY_ANCHOR) != IDENTITY_ANCHOR_SHA256:
        raise AssertionError("approved identity anchor missing or drifted")
    if not PIXEL_GRID_ANALYZER.is_file() or sha256_file(PIXEL_GRID_ANALYZER) != PIXEL_GRID_ANALYZER_SHA256:
        raise AssertionError("project pixel-grid analyzer missing or drifted")
    source_records = {key: audit_sheet(key, spec) for key, spec in SHEETS.items()}
    if any(record["direct_native"]["eligible"] for record in source_records.values()):
        raise AssertionError("unexpected direct-native pass")
    if any(record["exact_integer_display"]["eligible"] for record in source_records.values()):
        raise AssertionError("unexpected exact-integer-display pass")
    runtime_release = runtime_artifact_record()
    return {
        "schema_version": 2,
        "enemy_id": "combat_robot_main_battle_elite",
        "stage": STAGE,
        "audit_scope": "seven SHA-locked user-approved raw ImageGen animation sheets",
        "target_native_frame_size": TARGET_FRAME,
        "target_atlas_size": TARGET_ATLAS,
        "project_grid_diagnostic": {
            "tool_path": rel(PIXEL_GRID_ANALYZER),
            "tool_sha256": PIXEL_GRID_ANALYZER_SHA256,
            "command": "python dev_tools/pixel_grid_analyzer.py <approved_raw> --json",
            "all_sources_detection_mode": "native_or_unknown",
            "all_sources_grid_cell_size": 1,
            "note": "diagnostic output agrees with the stricter immutable-alpha phase proof but cannot itself grant admission",
        },
        "sources": source_records,
        "grid_evidence_mode": None,
        "direct_native_all_sources": False,
        "exact_integer_display_all_sources": False,
        "shared_square_integer_scale": None,
        "shared_grid_phase": None,
        "native_eligible": False,
        "human_approval_is_not_native_qualification": True,
        "native_block_reason": "neither direct_native nor exact_integer_display has positive evidence for every approved raw; native-alpha phase gcd is 1 for every sheet",
        "forbidden_asset_build_techniques_not_executed": [
            "resize",
            "downsample",
            "resample",
            "nearest-neighbor source reduction",
            "cell vote",
            "majority vote",
            "coverage vote",
            "per-frame scale fitting",
            "per-frame phase fitting",
            "semantic redraw",
        ],
        "runtime_linear_filtering_is_display_only": True,
        "third_gate_preview_written": False,
        "runtime_release": runtime_release,
        "runtime_written": True,
        "runtime_paths": [rel(path) for path in RUNTIME_PATHS.values()],
    }


def review_record() -> dict[str, Any]:
    records: dict[str, Any] = {}
    for key, spec in REVIEW_GIFS.items():
        path: Path = spec["path"]
        if not path.is_file() or sha256_file(path) != spec["sha256"]:
            raise AssertionError(f"approved review GIF missing or drifted: {key}")
        image = Image.open(path)
        decoded_durations = []
        for index in range(image.n_frames):
            image.seek(index)
            decoded_durations.append(image.info.get("duration"))
        if decoded_durations != spec["durations_ms"]:
            raise AssertionError(f"approved review timing drifted: {key}")
        records[key] = {
            "path": rel(path),
            "sha256": spec["sha256"],
            "frames": image.n_frames,
            "durations_ms": spec["durations_ms"],
            "review_only": True,
        }
    return records


def approval_payload(
    builder_sha: str,
    review: dict[str, Any],
    audit_path: str,
    runtime_release: dict[str, Any],
) -> dict[str, Any]:
    sources = {
        key: {
            "motion": spec["motion"],
            "path": rel(spec["path"]),
            "sha256": spec["sha256"],
            "frames": spec["frames"],
            "generation_record": rel(spec["prompt"]),
        }
        for key, spec in SHEETS.items()
    }
    return {
        "schema_version": 3,
        "enemy_id": "combat_robot_main_battle_elite",
        "stage": STAGE,
        "certificate_owner": rel(Path(__file__)),
        "builder_sha256": builder_sha,
        "human_approved": True,
        "approval_recorded_on": "2026-08-12",
        "approval_evidence": [
            "用户明确回复：很好，上述全部同意，开始继续处理",
        ],
        "approval_scope": "animation motion design, review timing, and the source-preserved high-resolution runtime display strategy; native64 qualification remains a separate technical gate",
        "selection": {
            "move": "m1",
            "normal_attack": "n2",
            "skill1": "c2",
            "skill2": "j1",
            "death": "d1",
        },
        "identity_anchor": {"path": rel(IDENTITY_ANCHOR), "sha256": IDENTITY_ANCHOR_SHA256},
        "approved_raw_sources": sources,
        "approved_review_gifs": review,
        "native_eligibility": {
            "eligible": False,
            "grid_evidence_mode": None,
            "audit_report": audit_path,
            "human_approval_is_not_native_qualification": True,
        },
        "runtime_release": runtime_release,
        "legacy_animation_materials": {
            "certificate_valid": False,
            "recoverable_by_rerun": False,
            "marker": rel(LEGACY_INVALID),
        },
        "final_candidate_built": True,
        "runtime_written": True,
        "runtime_paths": [rel(path) for path in RUNTIME_PATHS.values()],
    }


def legacy_payload(approval_sha: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "enemy_id": "combat_robot_main_battle_elite",
        "stage": "legacy_animation_materials_invalid",
        "certificate_valid": False,
        "recoverable_by_rerun": False,
        "canonical_approval": {"path": rel(APPROVAL), "sha256": approval_sha},
        "invalidated_certificates": [
            "dev_tools/output/asset_reports/combat_robot_main_battle_elite_animdraft_manifest.json",
            "dev_tools/output/asset_reports/combat_robot_main_battle_elite_animdraft_report.json",
            "dev_tools/output/asset_reports/combat_robot_main_battle_elite_animdraft_stability.json",
        ],
        "invalidated_output_glob": "dev_assets/generated_previews/combat_robot_main_battle_elite_animdraft_*",
        "invalidated_archived_direct_native_tree": "dev_assets/rejected_previews/combat_robot_main_battle_elite/direct_native_rejected_20260812",
        "blocked_legacy_builders": [
            "dev_tools/build_combat_robot_main_battle_elite_animation_draft_previews.py",
            "dev_tools/build_combat_robot_main_battle_elite_native_candidate.py",
        ],
        "reason": "old animdraft previews/certificates used superseded or compressed/non-integer material and cannot be promoted or regenerated as canonical outputs",
        "promotion_forbidden": True,
        "runtime_release_scope": "not_applicable_legacy_invalidation_only",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record-approval", action="store_true", help="write the exact user-approved canonical record")
    args = parser.parse_args()
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    builder_sha = sha256_file(Path(__file__))

    audit_1 = build_audit()
    review_1 = review_record()
    audit_2 = build_audit()
    review_2 = review_record()
    if audit_1 != audit_2 or review_1 != review_2:
        raise AssertionError("two-pass read-only audit drift")

    approval = approval_payload(builder_sha, review_2, rel(REPORT), audit_2["runtime_release"])
    approval_bytes = canonical_json(approval)
    if args.record_approval:
        APPROVAL.write_bytes(approval_bytes)
    elif not APPROVAL.is_file() or APPROVAL.read_bytes() != approval_bytes:
        raise AssertionError("canonical animation approval absent or drifted; use --record-approval after explicit human approval")

    approval_sha = sha256_bytes(approval_bytes)
    legacy = legacy_payload(approval_sha)
    legacy_bytes = canonical_json(legacy)
    LEGACY_INVALID.write_bytes(legacy_bytes)

    report = {
        **audit_2,
        "certificate_owner": rel(Path(__file__)),
        "builder_sha256": builder_sha,
        "canonical_approval": {"path": rel(APPROVAL), "sha256": approval_sha},
        "legacy_invalid_marker": {"path": rel(LEGACY_INVALID), "sha256": sha256_bytes(legacy_bytes)},
        "determinism": {"passes": 2, "drift_count": 0},
    }
    report_bytes = canonical_json(report)
    REPORT.write_bytes(report_bytes)

    snapshot = {
        rel(APPROVAL): approval_sha,
        rel(REPORT): sha256_bytes(report_bytes),
        rel(LEGACY_INVALID): sha256_bytes(legacy_bytes),
        rel(RUNTIME_BUILD_REPORT): sha256_file(RUNTIME_BUILD_REPORT),
        rel(RUNTIME_BUILDER): sha256_file(RUNTIME_BUILDER),
        **{rel(path): sha256_file(path) for path in RUNTIME_SUPPORT_PATHS.values()},
        **{rel(path): sha256_file(path) for path in RUNTIME_PATHS.values()},
    }
    stability = {
        "schema_version": 2,
        "enemy_id": "combat_robot_main_battle_elite",
        "stage": STAGE,
        "certificate_owner": rel(Path(__file__)),
        "builder_sha256": builder_sha,
        "passes": 2,
        "drift_count": 0,
        "snapshot_1": snapshot,
        "snapshot_2": snapshot,
        "current_snapshot": snapshot,
        "snapshot_exclusions": {rel(STABILITY): "self-referential stability certificate"},
        "runtime_release": audit_2["runtime_release"],
        "runtime_written": True,
        "runtime_paths": [rel(path) for path in RUNTIME_PATHS.values()],
    }
    STABILITY.write_bytes(canonical_json(stability))
    print(json.dumps({
        "status": "released_high_resolution_native64_ineligible",
        "stage": STAGE,
        "approval_sha256": approval_sha,
        "report_sha256": sha256_file(REPORT),
        "stability_sha256": sha256_file(STABILITY),
        "legacy_invalid_sha256": sha256_file(LEGACY_INVALID),
        "drift_count": 0,
        "runtime_strategy": RUNTIME_STRATEGY,
        "runtime_written": True,
    }, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
