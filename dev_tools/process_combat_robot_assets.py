#!/usr/bin/env python3
"""Build the combat-robot runtime sheet from four approved animation strips.

Input contract
--------------
The source directory must contain four horizontal strips with native transparent
Alpha:

* combat_robot_move_v2_imagegen.png: 8 poses;
* combat_robot_windup_v2_imagegen.png: 4 poses;
* combat_robot_dash_v2_imagegen.png: 4 poses;
* combat_robot_death_v2_imagegen.png: 8 poses.

Each strip contains exactly one row, no labels or grid lines, and wide empty
gutters between poses.  A pose, including its sword, must be one 8-connected
foreground component.  The square torso must be the thickest, largest solid
region in the pose.  All four strips must use the same source-space character
scale.

Processing contract
-------------------
Each independently generated strip gets one shared scale derived from its
median torso size and the same runtime torso target.  Thus source-resolution
differences between animations are normalized without ever scaling individual
frames.  A morphology-derived torso center is anchored at x=16 and every pose
lands on y=28.  The first approved move pose supplies one canonical
antenna/chassis/eye stamp.  Move also reuses one sword-arm stamp, while dash
reuses one complete upper-body thrust stamp; only their authored limb phases
remain variable.  The final visible bbox is at most 28x28.

Output is a 256x128 RGBA sheet of 32x32 cells, with rows move / windup / dash /
death.  Alpha is binary, transparent RGB is zero, and colors are snapped to the
fixed cold-steel plus red/orange palette.
"""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
import math
from pathlib import Path
from statistics import median

from PIL import Image, ImageFilter


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot"
OUTPUT_PATH = (
    PROJECT_ROOT
    / "resources/texture/enemy/mechanical_life/combat_robot.png"
)
PREVIEW_PATH = (
    PROJECT_ROOT
    / "dev_assets"
    / "generated_previews"
    / "combat_robot_sheet_preview.png"
)

GRID_COLUMNS = 8
GRID_ROWS = 4
FRAME_SIZE = 32
MAX_SUBJECT_SIZE = 28
FRAME_MARGIN = 0
BASELINE_Y = 28
TORSO_CENTER_X = 16.0
TARGET_TORSO_WIDTH = 12.0
TARGET_TORSO_HEIGHT = 13.0
MIN_RUNTIME_TORSO_SHORT_AXIS = 11.0
MIN_DASH_TORSO_SHORT_AXIS = 11.0
MIN_DEATH_TORSO_SHORT_AXIS = 8.0
ALPHA_THRESHOLD = 24
TORSO_EROSION_FRACTION = 0.05
CANONICAL_CHASSIS_SIZE = (12, 12)
CANONICAL_CHASSIS_RECT = (10, 10, 22, 22)
CANONICAL_CORE_SIZE = (12, 15)
CANONICAL_CORE_RECT = (10, 7, 22, 22)
CHASSIS_CLEAR_PADDING = 1
MOVE_WEAPON_RECT = (21, 9, 32, 23)
DASH_FIXED_CORE_RECT = (0, 0, 32, 22)
DEATH_CORE_Y_OFFSETS = (0, 1, 2)
MAX_COMPONENT_BRIDGE = 5


@dataclass(frozen=True)
class SourceStripSpec:
    animation: str
    filename: str
    frame_count: int


SOURCE_STRIPS: tuple[SourceStripSpec, ...] = (
    SourceStripSpec("move", "combat_robot_move_v2_imagegen.png", 8),
    SourceStripSpec("windup", "combat_robot_windup_v2_imagegen.png", 4),
    SourceStripSpec("dash", "combat_robot_dash_v2_imagegen.png", 4),
    SourceStripSpec("death", "combat_robot_death_v2_imagegen.png", 8),
)
ROW_SPECS: tuple[tuple[str, int], ...] = tuple(
    (spec.animation, spec.frame_count) for spec in SOURCE_STRIPS
)

# Compact cold-steel ramp with a hostile red/orange energy ramp.  Runtime art is
# snapped to these exact values to eliminate generated frame-to-frame color boil.
PALETTE: tuple[tuple[int, int, int, int], ...] = (
    (21, 22, 19, 255),       # near-black outline
    (29, 28, 30, 255),       # deepest chassis shadow
    (55, 59, 63, 255),       # joint shadow
    (82, 88, 94, 255),       # dark cold steel
    (112, 121, 128, 255),    # middle cold steel
    (151, 159, 164, 255),    # plate gray
    (190, 196, 198, 255),    # plate highlight
    (226, 229, 226, 255),    # blade / edge highlight
    (102, 25, 20, 255),      # deep red energy
    (190, 48, 31, 255),      # active red eye
    (239, 92, 34, 255),      # orange charge
    (255, 181, 71, 255),     # hot orange highlight
)
ACCENT_PALETTE = PALETTE[-4:]


@dataclass(frozen=True)
class ExtractedPose:
    animation: str
    source_frame: int
    image: Image.Image
    source_bbox: tuple[int, int, int, int]
    pixel_count: int
    torso_bbox: tuple[int, int, int, int]


def normalize_source(image: Image.Image, source_path: Path) -> Image.Image:
    """Return binary-alpha RGBA with transparent RGB normalized to zero."""
    if "A" not in image.getbands():
        raise ValueError(
            f"{source_path} has no Alpha channel. Provide an ImageGen strip "
            "exported with a native transparent background."
        )
    minimum_alpha, maximum_alpha = image.getchannel("A").getextrema()
    if minimum_alpha >= 255 or maximum_alpha == 0:
        raise ValueError(
            f"{source_path} must contain both transparent and visible pixels "
            "in its native Alpha channel."
        )
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= ALPHA_THRESHOLD:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return rgba


def _extract_mask_components(
    mask: Image.Image,
) -> list[tuple[int, tuple[int, int, int, int], list[tuple[int, int]]]]:
    """Return 8-connected nonzero mask components."""
    visible = mask.load()
    visited = bytearray(mask.width * mask.height)
    result: list[
        tuple[int, tuple[int, int, int, int], list[tuple[int, int]]]
    ] = []

    for start_y in range(mask.height):
        for start_x in range(mask.width):
            start_index = start_y * mask.width + start_x
            if visited[start_index] or visible[start_x, start_y] == 0:
                continue
            visited[start_index] = 1
            pending: deque[tuple[int, int]] = deque([(start_x, start_y)])
            points: list[tuple[int, int]] = []
            while pending:
                x, y = pending.popleft()
                points.append((x, y))
                for next_y in range(max(0, y - 1), min(mask.height, y + 2)):
                    for next_x in range(max(0, x - 1), min(mask.width, x + 2)):
                        next_index = next_y * mask.width + next_x
                        if (
                            visited[next_index]
                            or visible[next_x, next_y] == 0
                        ):
                            continue
                        visited[next_index] = 1
                        pending.append((next_x, next_y))

            left = min(point[0] for point in points)
            top = min(point[1] for point in points)
            right = max(point[0] for point in points) + 1
            bottom = max(point[1] for point in points) + 1
            result.append(
                (len(points), (left, top, right, bottom), points)
            )
    return result


def detect_torso_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    """Locate the thick square torso while rejecting thin limbs and sword.

    Eroding the alpha silhouette removes one-pixel-scale appendages.  The largest
    surviving component is the box chassis; expanding by the erosion radius
    restores an estimate of its authored outer bounds.
    """
    alpha = image.convert("RGBA").getchannel("A")
    subject_bbox = alpha.getbbox()
    if subject_bbox is None:
        raise ValueError("Cannot detect torso in an empty pose")
    subject_width = subject_bbox[2] - subject_bbox[0]
    subject_height = subject_bbox[3] - subject_bbox[1]
    erosion_radius = max(
        1,
        round(min(subject_width, subject_height) * TORSO_EROSION_FRACTION),
    )
    eroded = alpha.filter(
        ImageFilter.MinFilter(erosion_radius * 2 + 1)
    )
    components = _extract_mask_components(eroded)
    if not components:
        raise ValueError(
            "Torso detection found no thick alpha component; the square chassis "
            "must be the pose's largest solid region"
        )
    _count, core_bbox, _points = max(
        components,
        key=lambda item: (
            item[0],
            (item[1][2] - item[1][0]) * (item[1][3] - item[1][1]),
        ),
    )
    return (
        max(subject_bbox[0], core_bbox[0] - erosion_radius),
        max(subject_bbox[1], core_bbox[1] - erosion_radius),
        min(subject_bbox[2], core_bbox[2] + erosion_radius),
        min(subject_bbox[3], core_bbox[3] + erosion_radius),
    )


def _extract_strip(
    source_path: Path,
    animation: str,
    expected_count: int,
) -> list[ExtractedPose]:
    if not source_path.is_file():
        raise FileNotFoundError(
            f"Combat-robot source strip not found: {source_path}"
        )
    with Image.open(source_path) as source_image:
        source = normalize_source(source_image, source_path)
    raw_components = _extract_mask_components(source.getchannel("A"))
    if len(raw_components) != expected_count:
        raise ValueError(
            f"{source_path.name} has {len(raw_components)} connected poses in "
            f"native Alpha; expected {expected_count}. Component bboxes: "
            f"{[item[1] for item in raw_components]}"
        )

    source_pixels = source.load()
    poses: list[ExtractedPose] = []
    for source_frame, (pixel_count, bbox, points) in enumerate(
        sorted(raw_components, key=lambda item: (item[1][0], item[1][1]))
    ):
        left, top, right, bottom = bbox
        isolated = Image.new(
            "RGBA",
            (right - left, bottom - top),
            (0, 0, 0, 0),
        )
        isolated_pixels = isolated.load()
        for x, y in points:
            isolated_pixels[x - left, y - top] = source_pixels[x, y]
        torso_bbox = detect_torso_bbox(isolated)
        poses.append(
            ExtractedPose(
                animation=animation,
                source_frame=source_frame,
                image=isolated,
                source_bbox=bbox,
                pixel_count=pixel_count,
                torso_bbox=torso_bbox,
            )
        )
    return poses


def _color_distance(
    left: tuple[int, int, int, int],
    right: tuple[int, int, int, int],
) -> int:
    return (
        2 * (left[0] - right[0]) ** 2
        + 3 * (left[1] - right[1]) ** 2
        + 2 * (left[2] - right[2]) ** 2
    )


def snap_palette(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            pixels[x, y] = min(
                PALETTE,
                key=lambda color: _color_distance(
                    (red, green, blue, alpha),
                    color,
                ),
            )
    return rgba


def _build_canonical_core(pose: ExtractedPose) -> Image.Image:
    """Build one coarse antenna/chassis/eye stamp from move frame zero.

    The source pose is already an isolated ImageGen silhouette.  Cropping the
    torso width from the antenna top through the torso bottom excludes the
    animated arms and legs while retaining their rigid mounting box.  The last
    12 rows of the result are the canonical chassis; the first three rows hold
    the antenna.  This avoids deriving the runtime body from the older,
    over-detailed anchor image.
    """
    left, _top, right, bottom = pose.torso_bbox
    core = pose.image.crop((left, 0, right, bottom)).resize(
        CANONICAL_CORE_SIZE,
        Image.Resampling.BOX,
    )
    core = snap_palette(core)
    if core.getchannel("A").getbbox() is None:
        raise AssertionError("Canonical antenna/chassis core became empty")

    chassis = core.crop(
        (
            0,
            CANONICAL_CORE_SIZE[1] - CANONICAL_CHASSIS_SIZE[1],
            CANONICAL_CORE_SIZE[0],
            CANONICAL_CORE_SIZE[1],
        )
    )
    chassis_colors = set(chassis.getdata())
    if not chassis_colors.intersection(ACCENT_PALETTE):
        raise AssertionError("Canonical chassis lost its red/orange eye accent")
    return core


def _validate_runtime_frame(
    frame: Image.Image,
    animation: str,
    source_frame: int,
) -> tuple[int, int, int, int]:
    frame_bbox = frame.getchannel("A").getbbox()
    if frame_bbox is None:
        raise AssertionError(f"{animation}[{source_frame}] became empty")
    width = frame_bbox[2] - frame_bbox[0]
    height = frame_bbox[3] - frame_bbox[1]
    if width > MAX_SUBJECT_SIZE or height > MAX_SUBJECT_SIZE:
        raise AssertionError(
            f"{animation}[{source_frame}] bbox {frame_bbox} exceeds "
            f"{MAX_SUBJECT_SIZE}x{MAX_SUBJECT_SIZE}"
        )
    if (
        frame_bbox[0] < FRAME_MARGIN
        or frame_bbox[2] > FRAME_SIZE - FRAME_MARGIN
    ):
        raise AssertionError(
            f"{animation}[{source_frame}] bbox {frame_bbox} violates "
            f"the {FRAME_MARGIN}px horizontal review margin"
        )
    if frame_bbox[3] != BASELINE_Y:
        raise AssertionError(
            f"{animation}[{source_frame}] bbox {frame_bbox} misses "
            f"baseline y={BASELINE_Y}"
        )
    return frame_bbox


def _stamp_canonical_core(
    frame: Image.Image,
    original_torso_bbox: tuple[int, int, int, int],
    core: Image.Image,
    animation: str,
    source_frame: int,
    y_offset: int = 0,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    """Replace generated antenna/body pixels while preserving animated limbs."""
    result = frame.copy()
    left, top, right, bottom = original_torso_bbox
    frame_bbox = result.getchannel("A").getbbox()
    if frame_bbox is None:
        raise AssertionError(f"{animation}[{source_frame}] is empty")
    clear_bbox = (
        max(0, left - CHASSIS_CLEAR_PADDING),
        frame_bbox[1],
        min(FRAME_SIZE, right + CHASSIS_CLEAR_PADDING),
        min(FRAME_SIZE, bottom + CHASSIS_CLEAR_PADDING),
    )
    result.paste((0, 0, 0, 0), clear_bbox)
    destination = (
        CANONICAL_CORE_RECT[0],
        CANONICAL_CORE_RECT[1] + y_offset,
        CANONICAL_CORE_RECT[2],
        CANONICAL_CORE_RECT[3] + y_offset,
    )
    result.paste((0, 0, 0, 0), destination)
    result.alpha_composite(
        core,
        (destination[0], destination[1]),
    )

    _validate_runtime_frame(result, animation, source_frame)
    runtime_torso_bbox = detect_torso_bbox(result)
    runtime_torso_center = (
        runtime_torso_bbox[0] + runtime_torso_bbox[2]
    ) * 0.5
    if abs(runtime_torso_center - TORSO_CENTER_X) > 1.5:
        raise AssertionError(
            f"{animation}[{source_frame}] stamped core torso center "
            f"{runtime_torso_center:.2f} drifted from x={TORSO_CENTER_X:.1f}"
        )
    return result, runtime_torso_bbox


def _canonical_eye_pixels(core: Image.Image) -> list[tuple[int, int]]:
    """Return the widest horizontal accent run inside the chassis (the eye)."""
    chassis_top = CANONICAL_CORE_SIZE[1] - CANONICAL_CHASSIS_SIZE[1]
    pixels = core.load()
    best_run: list[tuple[int, int]] = []
    for y in range(chassis_top, core.height):
        current_run: list[tuple[int, int]] = []
        for x in range(core.width):
            if pixels[x, y] in ACCENT_PALETTE:
                current_run.append((x, y))
            else:
                if len(current_run) > len(best_run):
                    best_run = current_run
                current_run = []
        if len(current_run) > len(best_run):
            best_run = current_run
    if len(best_run) < 2:
        raise AssertionError(
            f"Canonical eye run is only {len(best_run)}px; expected at least 2"
        )
    return best_run


def _dim_canonical_eye(
    frame: Image.Image,
    core: Image.Image,
    y_offset: int,
    lit_pixels: int,
) -> None:
    """Dim the death eye without changing any chassis alpha geometry."""
    eye = _canonical_eye_pixels(core)
    frame_pixels = frame.load()
    center_start = max(0, (len(eye) - lit_pixels) // 2)
    lit_indices = set(range(center_start, center_start + lit_pixels))
    for index, (core_x, core_y) in enumerate(eye):
        destination = (
            CANONICAL_CORE_RECT[0] + core_x,
            CANONICAL_CORE_RECT[1] + y_offset + core_y,
        )
        frame_pixels[destination] = (
            PALETTE[8] if index in lit_indices else PALETTE[1]
        )


def _replace_region(
    frame: Image.Image,
    source: Image.Image,
    region: tuple[int, int, int, int],
) -> Image.Image:
    """Copy one exact rigid animation module between already aligned frames."""
    result = frame.copy()
    result.paste((0, 0, 0, 0), region)
    result.alpha_composite(source.crop(region), (region[0], region[1]))
    return result


def _draw_outline_bridge(
    frame: Image.Image,
    start: tuple[int, int],
    end: tuple[int, int],
) -> None:
    """Draw a one-pixel Bresenham bridge between two authored line parts."""
    x0, y0 = start
    x1, y1 = end
    delta_x = abs(x1 - x0)
    step_x = 1 if x0 < x1 else -1
    delta_y = -abs(y1 - y0)
    step_y = 1 if y0 < y1 else -1
    error = delta_x + delta_y
    pixels = frame.load()
    while True:
        if pixels[x0, y0][3] == 0:
            pixels[x0, y0] = PALETTE[0]
        if (x0, y0) == (x1, y1):
            break
        doubled = 2 * error
        if doubled >= delta_y:
            error += delta_y
            x0 += step_x
        if doubled <= delta_x:
            error += delta_x
            y0 += step_y


def _connect_runtime_components(
    frame: Image.Image,
    animation: str,
    source_frame: int,
) -> Image.Image:
    """Restore thin authored joints lost by source-to-runtime sampling.

    ImageGen source silhouettes are connected, but a one-source-block arm or
    shin can disappear when a whole strip is sampled at one scale.  This joins
    only the nearest components with a one-pixel outline segment and rejects a
    gap larger than five runtime pixels instead of inventing a new pose.
    """
    result = frame.copy()
    for _repair in range(16):
        components = _extract_mask_components(result.getchannel("A"))
        if len(components) <= 1:
            return result
        main = max(components, key=lambda item: item[0])
        main_points = main[2]
        best: tuple[int, int, tuple[int, int], tuple[int, int]] | None = None
        for component in components:
            if component is main:
                continue
            for main_point in main_points:
                for other_point in component[2]:
                    delta_x = abs(main_point[0] - other_point[0])
                    delta_y = abs(main_point[1] - other_point[1])
                    chebyshev = max(delta_x, delta_y)
                    squared = delta_x * delta_x + delta_y * delta_y
                    candidate = (
                        chebyshev,
                        squared,
                        main_point,
                        other_point,
                    )
                    if best is None or candidate < best:
                        best = candidate
        if best is None or best[0] > MAX_COMPONENT_BRIDGE:
            raise ValueError(
                f"{animation}[{source_frame}] has disconnected runtime parts "
                f"requiring a {best[0] if best else 'missing'}px bridge; "
                f"maximum is {MAX_COMPONENT_BRIDGE}px"
            )
        _draw_outline_bridge(result, best[2], best[3])
    raise AssertionError(
        f"{animation}[{source_frame}] component repair did not converge"
    )


def _strip_visual_scale(
    animation: str,
    poses: list[ExtractedPose],
) -> float:
    # Death's first three poses are the intact robot; later frames deliberately
    # rotate and collapse the chassis and must not redefine its authored scale.
    scale_reference_poses = poses[:3] if animation == "death" else poses
    torso_width = median(
        pose.torso_bbox[2] - pose.torso_bbox[0]
        for pose in scale_reference_poses
    )
    torso_height = median(
        pose.torso_bbox[3] - pose.torso_bbox[1]
        for pose in scale_reference_poses
    )
    desired_scale = min(
        TARGET_TORSO_WIDTH / torso_width,
        TARGET_TORSO_HEIGHT / torso_height,
        1.0,
    )

    fit_caps: list[float] = []
    for pose in poses:
        torso_center_x = (pose.torso_bbox[0] + pose.torso_bbox[2]) * 0.5
        left_extent = torso_center_x
        right_extent = pose.image.width - torso_center_x
        fit_caps.extend(
            (
                TORSO_CENTER_X / max(left_extent, 1.0),
                (FRAME_SIZE - TORSO_CENTER_X) / max(right_extent, 1.0),
                MAX_SUBJECT_SIZE / pose.image.width,
                MAX_SUBJECT_SIZE / pose.image.height,
            )
        )

    shared_scale = min(desired_scale, *fit_caps)
    if animation == "death":
        minimum_short_axis = MIN_DEATH_TORSO_SHORT_AXIS
    elif animation == "dash":
        minimum_short_axis = MIN_DASH_TORSO_SHORT_AXIS
    else:
        minimum_short_axis = MIN_RUNTIME_TORSO_SHORT_AXIS
    runtime_torso_short_axis = min(
        torso_width * shared_scale,
        torso_height * shared_scale,
    )
    # The final native raster uses ceil for a shared-scale sample; allow half a
    # source-to-runtime pixel here, then let the runtime audit enforce the exact
    # integer minimum on every frame.
    if runtime_torso_short_axis < minimum_short_axis - 0.5:
        raise ValueError(
            f"The {animation} strip would over-compress the robot at its shared "
            f"scale ({shared_scale:.5f}); median torso would be only "
            f"{torso_width * shared_scale:.2f}x"
            f"{torso_height * shared_scale:.2f}px. Shorten/repose the sword "
            "or tighten source whitespace rather than scaling frames independently."
        )
    return shared_scale


def _animation_visual_scales(
    poses_by_animation: dict[str, list[ExtractedPose]],
) -> dict[str, float]:
    return {
        animation: _strip_visual_scale(animation, poses)
        for animation, poses in poses_by_animation.items()
    }


def _build_frame(
    pose: ExtractedPose,
    shared_scale: float,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    target_size = (
        max(1, math.ceil(pose.image.width * shared_scale)),
        max(1, math.ceil(pose.image.height * shared_scale)),
    )
    subject = pose.image.resize(target_size, Image.Resampling.NEAREST)
    subject = snap_palette(subject)

    effective_scale_x = target_size[0] / pose.image.width
    source_torso_center_x = (
        pose.torso_bbox[0] + pose.torso_bbox[2]
    ) * 0.5
    runtime_torso_center_x = source_torso_center_x * effective_scale_x
    paste_x = round(TORSO_CENTER_X - runtime_torso_center_x)
    paste_y = BASELINE_Y - target_size[1]

    if (
        paste_x < 0
        or paste_x + target_size[0] > FRAME_SIZE
        or paste_y < 0
        or paste_y + target_size[1] > FRAME_SIZE
    ):
        raise AssertionError(
            f"{pose.animation}[{pose.source_frame}] shared placement "
            f"{(paste_x, paste_y)} size={target_size} would clip the pose"
        )

    frame = Image.new(
        "RGBA",
        (FRAME_SIZE, FRAME_SIZE),
        (0, 0, 0, 0),
    )
    frame.alpha_composite(subject, (paste_x, paste_y))
    _validate_runtime_frame(frame, pose.animation, pose.source_frame)

    runtime_torso_bbox = detect_torso_bbox(frame)
    runtime_torso_center = (
        runtime_torso_bbox[0] + runtime_torso_bbox[2]
    ) * 0.5
    if (
        pose.animation != "death"
        and abs(runtime_torso_center - TORSO_CENTER_X) > 1.5
    ):
        raise AssertionError(
            f"{pose.animation}[{pose.source_frame}] runtime torso center "
            f"{runtime_torso_center:.2f} drifted from x={TORSO_CENTER_X:.1f}"
        )
    return frame, runtime_torso_bbox


def build_sheet(
    source_dir: Path,
    output_path: Path,
) -> tuple[Image.Image, list[dict], dict[str, float]]:
    poses_by_animation: dict[str, list[ExtractedPose]] = {}
    for spec in SOURCE_STRIPS:
        poses = _extract_strip(
            source_dir / spec.filename,
            spec.animation,
            spec.frame_count,
        )
        poses_by_animation[spec.animation] = poses

    visual_scales = _animation_visual_scales(poses_by_animation)
    canonical_core = _build_canonical_core(poses_by_animation["move"][0])
    sheet = Image.new(
        "RGBA",
        (FRAME_SIZE * GRID_COLUMNS, FRAME_SIZE * GRID_ROWS),
        (0, 0, 0, 0),
    )
    report: list[dict] = []
    for row, spec in enumerate(SOURCE_STRIPS):
        animation_frames: list[Image.Image] = []
        animation_torso_bboxes: list[tuple[int, int, int, int]] = []
        for column, pose in enumerate(poses_by_animation[spec.animation]):
            visual_scale = visual_scales[spec.animation]
            frame, runtime_torso_bbox = _build_frame(pose, visual_scale)
            if spec.animation != "death":
                frame, runtime_torso_bbox = _stamp_canonical_core(
                    frame,
                    runtime_torso_bbox,
                    canonical_core,
                    spec.animation,
                    pose.source_frame,
                )
            elif column < len(DEATH_CORE_Y_OFFSETS):
                y_offset = DEATH_CORE_Y_OFFSETS[column]
                frame, runtime_torso_bbox = _stamp_canonical_core(
                    frame,
                    runtime_torso_bbox,
                    canonical_core,
                    spec.animation,
                    pose.source_frame,
                    y_offset,
                )
                if column > 0:
                    _dim_canonical_eye(
                        frame,
                        canonical_core,
                        y_offset,
                        lit_pixels=2,
                    )
            frame = _connect_runtime_components(
                frame,
                spec.animation,
                pose.source_frame,
            )
            animation_frames.append(frame)
            animation_torso_bboxes.append(runtime_torso_bbox)

        if spec.animation == "move":
            rigid_source = animation_frames[0]
            for column in range(1, len(animation_frames)):
                animation_frames[column] = _replace_region(
                    animation_frames[column],
                    rigid_source,
                    MOVE_WEAPON_RECT,
                )
        elif spec.animation == "dash":
            rigid_source = animation_frames[0]
            for column in range(1, len(animation_frames)):
                animation_frames[column] = _replace_region(
                    animation_frames[column],
                    rigid_source,
                    DASH_FIXED_CORE_RECT,
                )

        for column, (pose, frame) in enumerate(
            zip(poses_by_animation[spec.animation], animation_frames)
        ):
            frame = _connect_runtime_components(
                frame,
                spec.animation,
                column,
            )
            animation_frames[column] = frame
            _validate_runtime_frame(frame, spec.animation, column)
            runtime_torso_bbox = detect_torso_bbox(frame)
            animation_torso_bboxes[column] = runtime_torso_bbox
            sheet.alpha_composite(
                frame,
                (column * FRAME_SIZE, row * FRAME_SIZE),
            )
            report.append(
                {
                    "animation": spec.animation,
                    "frame": column,
                    "visual_scale": visual_scale,
                    "source_bbox": pose.source_bbox,
                    "source_torso_bbox": pose.torso_bbox,
                    "runtime_bbox": frame.getchannel("A").getbbox(),
                    "runtime_torso_bbox": runtime_torso_bbox,
                    "canonical_stamped": (
                        spec.animation != "death"
                        or column < len(DEATH_CORE_Y_OFFSETS)
                    ),
                }
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path, optimize=True)
    return sheet, report, visual_scales


def save_preview(
    sheet: Image.Image,
    preview_path: Path = PREVIEW_PATH,
) -> None:
    """Save a nearest-neighbour review image; this is not a runtime asset."""
    backdrop = Image.new("RGBA", sheet.size, (13, 19, 31, 255))
    backdrop.alpha_composite(sheet)
    preview = backdrop.resize(
        (sheet.width * 8, sheet.height * 8),
        Image.Resampling.NEAREST,
    )
    preview_path.parent.mkdir(parents=True, exist_ok=True)
    preview.save(preview_path, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Build the native 32px combat-robot sheet from four v2 strips"
        )
    )
    parser.add_argument(
        "source_dir",
        nargs="?",
        type=Path,
        default=SOURCE_DIR,
        help=f"directory containing four v2 strips (default: {SOURCE_DIR})",
    )
    parser.add_argument(
        "output_path",
        nargs="?",
        type=Path,
        default=OUTPUT_PATH,
        help=f"runtime sheet (default: {OUTPUT_PATH})",
    )
    args = parser.parse_args()
    sheet, report, visual_scales = build_sheet(
        args.source_dir,
        args.output_path,
    )
    save_preview(sheet)
    print(
        "COMBAT_ROBOT_ASSET_BUILD_OK "
        f"source_dir={args.source_dir} output={args.output_path} "
        f"size={sheet.width}x{sheet.height} frame={FRAME_SIZE}x{FRAME_SIZE} "
        "shared_scales="
        + ",".join(
            f"{name}:{visual_scales[name]:.6f}"
            for name, _count in ROW_SPECS
        )
        + f" baseline={BASELINE_Y} "
        f"max_bbox={MAX_SUBJECT_SIZE}x{MAX_SUBJECT_SIZE}"
    )
    print(f"  preview={PREVIEW_PATH}")
    for item in report:
        print(
            f"  {item['animation']}[{item['frame']}]: "
            f"scale={item['visual_scale']:.6f} "
            f"source_bbox={item['source_bbox']} "
            f"source_torso={item['source_torso_bbox']} "
            f"runtime_bbox={item['runtime_bbox']} "
            f"runtime_torso={item['runtime_torso_bbox']}"
        )


if __name__ == "__main__":
    main()
