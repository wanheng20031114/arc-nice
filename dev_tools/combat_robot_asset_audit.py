#!/usr/bin/env python3
"""Audit combat-robot geometry, temporal stability, and SpriteFrames contracts."""

from __future__ import annotations

import hashlib
import math
from pathlib import Path
import re
from statistics import median

from PIL import Image

from process_combat_robot_assets import (
    ACCENT_PALETTE,
    BASELINE_Y,
    CANONICAL_CHASSIS_RECT,
    CANONICAL_CHASSIS_SIZE,
    CANONICAL_CORE_RECT,
    CANONICAL_CORE_SIZE,
    DASH_FIXED_CORE_RECT,
    DEATH_CORE_Y_OFFSETS,
    FRAME_SIZE,
    GRID_COLUMNS,
    GRID_ROWS,
    MAX_SUBJECT_SIZE,
    MIN_DASH_TORSO_SHORT_AXIS,
    MIN_RUNTIME_TORSO_SHORT_AXIS,
    MOVE_WEAPON_RECT,
    OUTPUT_PATH,
    PALETTE,
    PROJECT_ROOT,
    ROW_SPECS,
    TORSO_CENTER_X,
    _extract_mask_components,
    detect_torso_bbox,
)


ANIMATION_RESOURCE_PATH = (
    PROJECT_ROOT / "resources" / "animation" / "combat_robot.tres"
)
ANIMATION_CONTRACT = {
    "move": {"frames": 8, "speed": 14.0, "loop": True, "row": 0},
    "windup": {"frames": 4, "speed": 10.0, "loop": False, "row": 1},
    "dash": {"frames": 4, "speed": 12.0, "loop": True, "row": 2},
    "death": {"frames": 8, "speed": 12.0, "loop": False, "row": 3},
}

MAX_TORSO_CENTER_DRIFT = 0.5
MAX_MOVE_TORSO_AXIS_DRIFT = 1
MAX_MOVE_TORSO_Y_DRIFT = 0.5
MAX_ANIMATION_TORSO_SCALE_DRIFT = 1.0
MAX_CROSS_ANIMATION_TORSO_SCALE_DRIFT = 1.0
MAX_MOVE_TORSO_FILL_DRIFT = 0.04

# The approved warning-color pass intentionally replaces some of the original
# red/orange ramp without changing geometry.  Keep those authored colors
# explicit so the audit still rejects arbitrary palette drift, while temporal
# comparisons normalize every approved warning color to one semantic accent.
APPROVED_WARNING_ACCENT_PALETTE = (
    (185, 75, 80, 255),
    (236, 28, 36, 255),
    (255, 0, 0, 255),
)
RUNTIME_PALETTE = (*PALETTE, *APPROVED_WARNING_ACCENT_PALETTE)
RUNTIME_ACCENT_PALETTE = (
    *ACCENT_PALETTE,
    *APPROVED_WARNING_ACCENT_PALETTE,
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _frame(sheet: Image.Image, row: int, column: int) -> Image.Image:
    return sheet.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )


def _assert_binary_clean_alpha(image: Image.Image) -> None:
    for index, (red, green, blue, alpha) in enumerate(image.getdata()):
        if alpha not in (0, 255):
            raise AssertionError(f"Partial alpha at flat pixel {index}: {alpha}")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(
                f"Transparent RGB residue at flat pixel {index}: "
                f"{(red, green, blue)}"
            )


def _assert_palette(image: Image.Image) -> None:
    allowed = set(RUNTIME_PALETTE)
    visible = {pixel for pixel in image.getdata() if pixel[3] > 0}
    unexpected = visible - allowed
    if unexpected:
        raise AssertionError(
            f"Runtime sheet contains colors outside palette: {unexpected}"
        )


def _torso_metrics(
    frame: Image.Image,
    torso_bbox: tuple[int, int, int, int],
) -> dict:
    left, top, right, bottom = torso_bbox
    width = right - left
    height = bottom - top
    torso = frame.crop(torso_bbox)
    opaque_count = sum(pixel[3] > 0 for pixel in torso.getdata())
    area = width * height
    visible_colors = {
        pixel for pixel in torso.getdata() if pixel[3] > 0
    }
    return {
        "torso_bbox": torso_bbox,
        "torso_center_x": (left + right) * 0.5,
        "torso_center_y": (top + bottom) * 0.5,
        "torso_width": width,
        "torso_height": height,
        "torso_scale": math.sqrt(float(area)),
        "torso_fill": opaque_count / max(area, 1),
        "torso_colors": visible_colors,
    }


def _range(values: list[float]) -> float:
    if not values:
        return 0.0
    return max(values) - min(values)


def _matches_opaque_stamp(
    reference: tuple[tuple[int, int, int, int], ...],
    candidate: tuple[tuple[int, int, int, int], ...],
) -> bool:
    """Compare authored rigid pixels while allowing limb joints in empty edge cells."""
    return all(
        reference_pixel[3] == 0
        or _normalize_warning_accent(reference_pixel)
        == _normalize_warning_accent(candidate_pixel)
        for reference_pixel, candidate_pixel in zip(reference, candidate)
    )


def _normalize_warning_accent(
    pixel: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    if pixel in RUNTIME_ACCENT_PALETTE:
        return ACCENT_PALETTE[0]
    return pixel


def _normalized_pixels(
    image: Image.Image,
) -> tuple[tuple[int, int, int, int], ...]:
    return tuple(_normalize_warning_accent(pixel) for pixel in image.getdata())


def _assert_temporal_stability(report: list[dict]) -> None:
    grouped: dict[str, list[dict]] = {
        animation_name: [] for animation_name, _count in ROW_SPECS
    }
    for item in report:
        grouped[item["animation"]].append(item)

    living_frames = [
        item
        for animation_name in ("move", "windup", "dash")
        for item in grouped[animation_name]
    ]
    canonical_core_pixels = living_frames[0]["canonical_core_pixels"]
    core_mismatches = [
        f"{item['animation']}[{item['frame']}]"
        for item in living_frames
        if not _matches_opaque_stamp(
            canonical_core_pixels,
            item["canonical_core_pixels"],
        )
    ]
    if core_mismatches:
        raise AssertionError(
            "Canonical antenna/chassis core flickers in: "
            + ", ".join(core_mismatches)
        )

    canonical_pixels = living_frames[0]["canonical_chassis_pixels"]
    mismatches = [
        f"{item['animation']}[{item['frame']}]"
        for item in living_frames
        if not _matches_opaque_stamp(
            canonical_pixels,
            item["canonical_chassis_pixels"],
        )
    ]
    if mismatches:
        raise AssertionError(
            "Canonical chassis/eye pixels flicker in: " + ", ".join(mismatches)
        )

    canonical_colors = set(living_frames[0]["canonical_chassis_colors"])
    if not canonical_colors.intersection(RUNTIME_ACCENT_PALETTE):
        raise AssertionError("Canonical chassis crop lacks its red/orange eye")
    steel_colors = set(PALETTE[:8])
    if len(canonical_colors.intersection(steel_colors)) < 3:
        raise AssertionError(
            "Canonical chassis crop uses fewer than three cold-steel colors"
        )

    death_start = grouped["death"][0]
    if not _matches_opaque_stamp(
        canonical_core_pixels,
        death_start["canonical_core_pixels"],
    ):
        raise AssertionError(
            "death[0] does not reuse the exact living antenna/chassis core"
        )

    move_weapon_pixels = grouped["move"][0]["move_weapon_pixels"]
    move_weapon_mismatches = [
        item["frame"]
        for item in grouped["move"]
        if item["move_weapon_pixels"] != move_weapon_pixels
    ]
    if move_weapon_mismatches:
        raise AssertionError(
            "Move sword-arm module flickers in frames: "
            f"{move_weapon_mismatches}"
        )

    dash_core_pixels = grouped["dash"][0]["dash_fixed_core_pixels"]
    dash_core_mismatches = [
        item["frame"]
        for item in grouped["dash"]
        if item["dash_fixed_core_pixels"] != dash_core_pixels
    ]
    if dash_core_mismatches:
        raise AssertionError(
            "Dash upper-body/sword force line flickers in frames: "
            f"{dash_core_mismatches}"
        )

    move_lower_masks = [item["lower_alpha"] for item in grouped["move"]]
    if len(set(move_lower_masks)) != len(move_lower_masks):
        raise AssertionError(
            "Move must preserve eight distinct generated lower-body phases"
        )
    dash_lower_masks = [item["lower_alpha"] for item in grouped["dash"]]
    if len(set(dash_lower_masks)) != len(dash_lower_masks):
        raise AssertionError(
            "Dash must preserve four distinct generated lower-body phases"
        )

    living_animation_scales: list[float] = []
    for animation_name in ("move", "windup", "dash"):
        frames = grouped[animation_name]
        center_x_values = [
            float(item["torso_center_x"]) for item in frames
        ]
        if _range(center_x_values) > MAX_TORSO_CENTER_DRIFT:
            raise AssertionError(
                f"{animation_name} torso x centers drift by "
                f"{_range(center_x_values):.2f}px: {center_x_values}"
            )
        for frame_index, center_x in enumerate(center_x_values):
            if abs(center_x - TORSO_CENTER_X) > MAX_TORSO_CENTER_DRIFT:
                raise AssertionError(
                    f"{animation_name}[{frame_index}] torso center x="
                    f"{center_x:.2f}, expected {TORSO_CENTER_X:.1f}±"
                    f"{MAX_TORSO_CENTER_DRIFT:.1f}"
                )

        short_axes = [
            min(int(item["torso_width"]), int(item["torso_height"]))
            for item in frames
        ]
        minimum_short_axis = (
            MIN_DASH_TORSO_SHORT_AXIS
            if animation_name == "dash"
            else MIN_RUNTIME_TORSO_SHORT_AXIS
        )
        if min(short_axes) < minimum_short_axis:
            raise AssertionError(
                f"{animation_name} is over-compressed: torso short axes "
                f"{short_axes}, minimum {minimum_short_axis:.1f}px"
            )

        scales = [float(item["torso_scale"]) for item in frames]
        if _range(scales) > MAX_ANIMATION_TORSO_SCALE_DRIFT:
            raise AssertionError(
                f"{animation_name} torso scale flickers by "
                f"{_range(scales):.2f}px: {scales}"
            )
        living_animation_scales.append(float(median(scales)))

    if _range(living_animation_scales) > MAX_CROSS_ANIMATION_TORSO_SCALE_DRIFT:
        raise AssertionError(
            "Shared visual scale drifted between move/windup/dash: "
            f"{living_animation_scales}"
        )

    move_frames = grouped["move"]
    move_widths = [float(item["torso_width"]) for item in move_frames]
    move_heights = [float(item["torso_height"]) for item in move_frames]
    move_center_y = [
        float(item["torso_center_y"]) for item in move_frames
    ]
    move_fill = [float(item["torso_fill"]) for item in move_frames]
    if (
        _range(move_widths) > MAX_MOVE_TORSO_AXIS_DRIFT
        or _range(move_heights) > MAX_MOVE_TORSO_AXIS_DRIFT
    ):
        raise AssertionError(
            "Move torso dimensions flicker: "
            f"widths={move_widths}, heights={move_heights}"
        )
    if _range(move_center_y) > MAX_MOVE_TORSO_Y_DRIFT:
        raise AssertionError(
            f"Move torso y center drifts by {_range(move_center_y):.2f}px: "
            f"{move_center_y}"
        )
    if _range(move_fill) > MAX_MOVE_TORSO_FILL_DRIFT:
        raise AssertionError(
            f"Move torso fill flickers by {_range(move_fill):.3f}: "
            f"{move_fill}"
        )

    move_steel_sets = [
        set(item["torso_colors"]).intersection(steel_colors)
        for item in move_frames
    ]
    common_steel_colors = set.intersection(*move_steel_sets)
    if len(common_steel_colors) < 3:
        raise AssertionError(
            "Move torso palette flickers: fewer than three steel colors are "
            f"shared by every frame ({common_steel_colors})"
        )


def _assert_sheet_contract(sheet: Image.Image) -> list[dict]:
    expected_size = (
        FRAME_SIZE * GRID_COLUMNS,
        FRAME_SIZE * GRID_ROWS,
    )
    if sheet.size != expected_size:
        raise AssertionError(
            f"Runtime sheet is {sheet.size}, expected {expected_size}"
        )

    _assert_binary_clean_alpha(sheet)
    _assert_palette(sheet)
    accent_colors = set(RUNTIME_ACCENT_PALETTE)
    outline = PALETTE[0]
    report: list[dict] = []

    for row, (animation_name, frame_count) in enumerate(ROW_SPECS):
        for column in range(GRID_COLUMNS):
            frame = _frame(sheet, row, column)
            bbox = frame.getchannel("A").getbbox()
            if column >= frame_count:
                if bbox is not None:
                    raise AssertionError(
                        f"Unused runtime cell row={row}, column={column} "
                        "is not empty"
                    )
                continue
            if bbox is None:
                raise AssertionError(f"{animation_name}[{column}] is empty")

            width = bbox[2] - bbox[0]
            height = bbox[3] - bbox[1]
            if width > MAX_SUBJECT_SIZE or height > MAX_SUBJECT_SIZE:
                raise AssertionError(
                    f"{animation_name}[{column}] bbox {bbox} exceeds "
                    f"{MAX_SUBJECT_SIZE}x{MAX_SUBJECT_SIZE}"
                )
            if bbox[3] != BASELINE_Y:
                raise AssertionError(
                    f"{animation_name}[{column}] bbox {bbox} misses "
                    f"y={BASELINE_Y} baseline"
                )

            visible_colors = {
                pixel for pixel in frame.getdata() if pixel[3] > 0
            }
            component_count = len(
                _extract_mask_components(frame.getchannel("A"))
            )
            if component_count != 1:
                raise AssertionError(
                    f"{animation_name}[{column}] has {component_count} "
                    "disconnected runtime components"
                )
            if animation_name != "death":
                if outline not in visible_colors:
                    raise AssertionError(
                        f"{animation_name}[{column}] lacks fixed outline color"
                    )
                if not visible_colors.intersection(accent_colors):
                    raise AssertionError(
                        f"{animation_name}[{column}] lacks red/orange accent"
                    )

            if animation_name != "death":
                torso_bbox = CANONICAL_CHASSIS_RECT
            elif column < len(DEATH_CORE_Y_OFFSETS):
                y_offset = DEATH_CORE_Y_OFFSETS[column]
                torso_bbox = (
                    CANONICAL_CHASSIS_RECT[0],
                    CANONICAL_CHASSIS_RECT[1] + y_offset,
                    CANONICAL_CHASSIS_RECT[2],
                    CANONICAL_CHASSIS_RECT[3] + y_offset,
                )
            else:
                torso_bbox = detect_torso_bbox(frame)
            metrics = _torso_metrics(frame, torso_bbox)
            canonical_chassis = None
            canonical_colors = None
            canonical_core = None
            core_rect = CANONICAL_CORE_RECT
            if animation_name != "death" or column == 0:
                canonical_core = frame.crop(core_rect)
                if canonical_core.size != CANONICAL_CORE_SIZE:
                    raise AssertionError(
                        f"Canonical core crop is {canonical_core.size}, "
                        f"expected {CANONICAL_CORE_SIZE}"
                    )
            if animation_name != "death" or column == 0:
                canonical_chassis = frame.crop(torso_bbox)
                if canonical_chassis.size != CANONICAL_CHASSIS_SIZE:
                    raise AssertionError(
                        f"Canonical chassis crop is {canonical_chassis.size}, "
                        f"expected {CANONICAL_CHASSIS_SIZE}"
                    )
                canonical_colors = {
                    pixel
                    for pixel in canonical_chassis.getdata()
                    if pixel[3] > 0
                }
            report.append(
                {
                    "animation": animation_name,
                    "frame": column,
                    "bbox": bbox,
                    "component_count": component_count,
                    "canonical_core_pixels": (
                        tuple(canonical_core.getdata())
                        if canonical_core is not None
                        else None
                    ),
                    "canonical_chassis_pixels": (
                        tuple(canonical_chassis.getdata())
                        if canonical_chassis is not None
                        else None
                    ),
                    "canonical_chassis_colors": canonical_colors,
                    "move_weapon_pixels": (
                        _normalized_pixels(frame.crop(MOVE_WEAPON_RECT))
                        if animation_name == "move"
                        else None
                    ),
                    "dash_fixed_core_pixels": (
                        _normalized_pixels(frame.crop(DASH_FIXED_CORE_RECT))
                        if animation_name == "dash"
                        else None
                    ),
                    "lower_alpha": frame.getchannel("A").crop(
                        (0, CANONICAL_CHASSIS_RECT[3], FRAME_SIZE, FRAME_SIZE)
                    ).tobytes(),
                    **metrics,
                }
            )

    _assert_temporal_stability(report)
    return report


def _parse_animation_blocks(text: str) -> dict[str, dict]:
    pattern = re.compile(
        r'\{\s*"frames": \[(.*?)\],\s*'
        r'"loop": (true|false),\s*'
        r'"name": &"([^"]+)",\s*'
        r'"speed": ([0-9.]+)\s*\}',
        re.DOTALL,
    )
    result: dict[str, dict] = {}
    for frames_text, loop_text, name, speed_text in pattern.findall(text):
        if name in result:
            raise AssertionError(f"Duplicate animation in resource: {name}")
        result[name] = {
            "frames": frames_text.count('"texture": SubResource('),
            "loop": loop_text == "true",
            "speed": float(speed_text),
        }
    return result


def _assert_animation_resource() -> None:
    if not ANIMATION_RESOURCE_PATH.is_file():
        raise FileNotFoundError(ANIMATION_RESOURCE_PATH)
    text = ANIMATION_RESOURCE_PATH.read_text(encoding="utf-8")
    texture_path = 'path="res://resources/texture/combat_robot.png"'
    if text.count(texture_path) != 1:
        raise AssertionError(
            "SpriteFrames must reference combat_robot.png exactly once"
        )

    expected_atlas_count = sum(spec[1] for spec in ROW_SPECS)
    actual_atlas_count = text.count(
        '[sub_resource type="AtlasTexture"'
    )
    if actual_atlas_count != expected_atlas_count:
        raise AssertionError(
            f"SpriteFrames has {actual_atlas_count} atlases, expected "
            f"{expected_atlas_count}"
        )

    for animation_name, expected in ANIMATION_CONTRACT.items():
        row = int(expected["row"])
        for column in range(int(expected["frames"])):
            atlas_id = f"AtlasTexture_{animation_name}_{column}"
            atlas_marker = (
                f'[sub_resource type="AtlasTexture" id="{atlas_id}"]'
            )
            region_marker = (
                f"region = Rect2({column * FRAME_SIZE}, "
                f"{row * FRAME_SIZE}, {FRAME_SIZE}, {FRAME_SIZE})"
            )
            if (
                text.count(atlas_marker) != 1
                or text.count(region_marker) < 1
            ):
                raise AssertionError(
                    f"Missing atlas contract for "
                    f"{animation_name}[{column}]"
                )

    parsed = _parse_animation_blocks(text)
    if set(parsed) != set(ANIMATION_CONTRACT):
        raise AssertionError(
            f"Animation names are {sorted(parsed)}, expected "
            f"{sorted(ANIMATION_CONTRACT)}"
        )
    for name, expected in ANIMATION_CONTRACT.items():
        actual = parsed[name]
        if actual["frames"] != expected["frames"]:
            raise AssertionError(
                f"{name} has {actual['frames']} frames, expected "
                f"{expected['frames']}"
            )
        if actual["loop"] != expected["loop"]:
            raise AssertionError(
                f"{name} loop={actual['loop']}, expected "
                f"{expected['loop']}"
            )
        if actual["speed"] != expected["speed"]:
            raise AssertionError(
                f"{name} speed={actual['speed']}, expected "
                f"{expected['speed']}"
            )


def main() -> None:
    _assert_animation_resource()
    if not OUTPUT_PATH.is_file():
        raise FileNotFoundError(
            f"Runtime sheet not found: {OUTPUT_PATH}. Run "
            "process_combat_robot_assets.py after all four v2 strips arrive."
        )
    sheet = Image.open(OUTPUT_PATH).convert("RGBA")
    report = _assert_sheet_contract(sheet)
    print(
        "COMBAT_ROBOT_ASSET_AUDIT_OK "
        f"sheet={OUTPUT_PATH} size={sheet.width}x{sheet.height} "
        f"sha256={_sha256(OUTPUT_PATH)} "
        "components=24/24-connected canonical_chassis=16/16-exact "
        "move_lower_masks=8/8-unique dash_lower_masks=4/4-unique"
    )
    for item in report:
        print(
            f"  {item['animation']}[{item['frame']}]: "
            f"bbox={item['bbox']} torso={item['torso_bbox']} "
            f"center=({item['torso_center_x']:.2f},"
            f"{item['torso_center_y']:.2f}) "
            f"scale={item['torso_scale']:.2f} "
            f"fill={item['torso_fill']:.3f}"
        )


if __name__ == "__main__":
    main()
