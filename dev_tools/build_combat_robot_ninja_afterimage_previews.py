#!/usr/bin/env python3
"""Package Godot-rendered ninja afterimage review frames into PNG/GIF previews."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path
from shutil import copyfile

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
RAW_DIRECTORY = ROOT / "dev_tools" / "output" / "combat_robot_ninja_afterimage_shader"
OUTPUT_DIRECTORY = ROOT / "dev_assets" / "generated_previews"
STATUS_SHADER = ROOT / "scene" / "entity_motion_status.gdshader"
FRAME_COUNT = 8
FRAME_DURATION_MS = round(1000 / 24)
VARIANTS = (
    ("v1", "full_strength"),
    ("v2", "medium_strength"),
    ("v3", "light_strength"),
)


def _require(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(f"Missing Godot-rendered preview input: {path}")
    return path


def _save_gif(frame_paths: list[Path], output_path: Path) -> None:
    frames = [Image.open(_require(path)).convert("RGB") for path in frame_paths]
    palette = frames[0].quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    quantized = [
        frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames
    ]
    quantized[0].save(
        output_path,
        save_all=True,
        append_images=quantized[1:],
        duration=FRAME_DURATION_MS,
        loop=0,
        optimize=False,
        disposal=2,
    )
    for frame in frames:
        frame.close()


def main() -> None:
    OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    raw_report_path = _require(RAW_DIRECTORY / "runtime_report.json")
    raw_report = json.loads(raw_report_path.read_text(encoding="utf-8"))
    if raw_report.get("failures"):
        raise RuntimeError(f"Godot shader preview reported failures: {raw_report['failures']}")
    if raw_report.get("review_algorithm") != (
        "production_original_rgb_three_offset_afterimage"
    ):
        raise RuntimeError("Godot did not render the production afterimage shader.")
    if raw_report.get("production_shader_used_directly") is not True:
        raise RuntimeError("Review must load the production shader without injection.")
    if raw_report.get("sample_rgb") != "original texture RGB":
        raise RuntimeError("Review afterimages must preserve sampled texture RGB.")
    body_changes = raw_report.get("body_changed_pixels_by_sprite", {})
    if not body_changes or any(int(value) != 0 for value in body_changes.values()):
        raise RuntimeError(f"Afterimage changed original body pixels: {body_changes}")
    trail_changes = raw_report.get("trail_only_changed_pixels_by_sprite", {})
    if not trail_changes or any(int(value) <= 0 for value in trail_changes.values()):
        raise RuntimeError(f"Afterimage did not produce trail-only pixels: {trail_changes}")
    trail_intersections = raw_report.get(
        "trail_body_intersection_pixels_by_sprite", {}
    )
    if not trail_intersections or any(
        int(value) != 0 for value in trail_intersections.values()
    ):
        raise RuntimeError(f"Afterimage intersected original body: {trail_intersections}")
    world_direction_dots = raw_report.get(
        "trail_world_direction_dot_by_sprite", {}
    )
    if not world_direction_dots or any(
        float(value) >= -0.5 for value in world_direction_dots.values()
    ):
        raise RuntimeError(
            f"Afterimage centroid is not behind world motion: {world_direction_dots}"
        )
    projections = raw_report.get("opposite_direction_projection_by_sprite", {})
    if not projections or any(float(value) <= 0.5 for value in projections.values()):
        raise RuntimeError(f"Afterimage is not behind world motion: {projections}")
    if raw_report.get("atlas_frame_count") != FRAME_COUNT:
        raise RuntimeError("Godot did not review all eight S1 AtlasTexture frames.")
    if raw_report.get("atlas_filter_clip") is not True:
        raise RuntimeError("S1 AtlasTexture preview did not enable filter_clip.")
    atlas_differences = raw_report.get(
        "atlas_standalone_changed_pixels_by_frame", {}
    )
    if len(atlas_differences) != FRAME_COUNT or any(
        int(value) != 0 for value in atlas_differences.values()
    ):
        raise RuntimeError(
            f"AtlasTexture rendering diverged from standalone frames: {atlas_differences}"
        )

    board_output = (
        OUTPUT_DIRECTORY / "combat_robot_ninja_afterimage_shader_board.png"
    )
    copyfile(_require(RAW_DIRECTORY / "board_02.png"), board_output)

    outputs: dict[str, dict[str, str | int]] = {}
    for variant_id, variant_name in VARIANTS:
        frame_paths = [
            RAW_DIRECTORY / f"{variant_id}_{frame_index:02d}.png"
            for frame_index in range(FRAME_COUNT)
        ]
        static_output = OUTPUT_DIRECTORY / (
            f"combat_robot_ninja_afterimage_{variant_id}_{variant_name}.png"
        )
        gif_output = OUTPUT_DIRECTORY / (
            f"combat_robot_ninja_afterimage_{variant_id}_{variant_name}.gif"
        )
        copyfile(_require(frame_paths[2]), static_output)
        _save_gif(frame_paths, gif_output)
        outputs[variant_id] = {
            "static": static_output.relative_to(ROOT).as_posix(),
            "gif": gif_output.relative_to(ROOT).as_posix(),
            "gif_bytes": gif_output.stat().st_size,
        }

    shader_digest = hashlib.sha256(STATUS_SHADER.read_bytes()).hexdigest()
    if shader_digest != raw_report.get("status_shader_sha256"):
        raise RuntimeError(
            "The runtime shader changed between Godot capture and preview packaging."
        )
    final_report = {
        **raw_report,
        "packaged_board": board_output.relative_to(ROOT).as_posix(),
        "packaged_variants": outputs,
        "gif_frame_count": FRAME_COUNT,
        "gif_frame_duration_ms": FRAME_DURATION_MS,
    }
    report_output = (
        enemy_asset_report_path("combat_robot_ninja_afterimage_shader_report.json")
    )
    report_output.write_text(
        json.dumps(final_report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        "COMBAT_ROBOT_NINJA_AFTERIMAGE_PREVIEWS_OK "
        f"board={board_output} variants={len(VARIANTS)}"
    )


if __name__ == "__main__":
    main()
