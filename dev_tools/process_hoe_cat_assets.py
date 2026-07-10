#!/usr/bin/env python3
"""Build the rebuilt Hoe Cat runtime sprites from original imagegen sources.

The source boards in ``dev_assets/source_images/hoe_cat_rebuild`` are new,
independent artwork.  This pipeline deliberately does not read the previous Hoe
Cat sprites.  It extracts one stable authored component per character frame,
uses one shared scale, mirrors the right-facing art for the left direction, and
registers the result on a native 32 px logical grid.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
import sys

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "dev_tools"))

from pixel_crop_tool import normalize_transparency  # noqa: E402
from pixel_grid_analyzer import analyze_image  # noqa: E402


SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "hoe_cat_rebuild"
OUTPUT_DIR = ROOT / "resources" / "texture" / "player" / "hoe_cat"
PREVIEW_PATH = ROOT / "tmp" / "hoe_cat_rebuild_preview.png"

MOVE_COLUMNS = 4
MOVE_ROWS = 4
ATTACK_COLUMNS = 5
ATTACK_ROWS = 4
DEATH_COLUMNS = 5
FRAME_SIZE = 32
SLASH_FRAME_SIZE = 112
SLASH_FRAME_COUNT = 8
SLASH_SOURCE_COLUMNS = 4
SLASH_SOURCE_ROWS = 2
SLASH_PEAK_FRAME_INDICES = (3, 4)
SLASH_ATTACK_RADIUS = 48.0
# The generated brush arc is intentionally wider than the hit cone. Compress
# its cross-axis motion instead of cutting it with a sector mask: the bright
# body stays close to gameplay while the authored tips remain naturally
# tapered, like the Swordsman Cat slash reference.
SLASH_CROSS_AXIS_SCALE = 0.78
SLASH_ALPHA_FLOOR = 2
SLASH_ALPHA_TRANSPARENT_POINT = 24
SLASH_ALPHA_OPAQUE_POINT = 216
WHIRLWIND_VFX_FRAME_SIZE = 48
WHIRLWIND_ICON_SIZE = 128
WHIRLWIND_ICON_SUBJECT_SIZE = 112
ALPHA_THRESHOLD = 56
VFX_PALETTE = [
    (60, 31, 18),
    (107, 51, 26),
    (161, 98, 59),
    (227, 160, 91),
    (239, 185, 107),
    (244, 204, 131),
    (248, 219, 151),
    (253, 234, 161),
]
SLASH_PALETTE = [
    (111, 74, 18),
    (169, 104, 25),
    (216, 151, 40),
    (240, 200, 74),
    (255, 228, 119),
    (255, 241, 166),
    (255, 248, 215),
    (255, 255, 240),
]
WHIRLWIND_ICON_PALETTE = [
    (33, 17, 13),
    (73, 40, 24),
    (117, 61, 32),
    (165, 91, 46),
    (104, 99, 84),
    (218, 208, 177),
    *SLASH_PALETTE,
]


@dataclass(frozen=True)
class Component:
    bbox: tuple[int, int, int, int]
    size: int
    center_x: float
    center_y: float


def _load_source(name: str) -> Image.Image:
    path = SOURCE_DIR / name
    if not path.is_file():
        raise FileNotFoundError(path)
    return normalize_transparency(
        Image.open(path),
        alpha_threshold=ALPHA_THRESHOLD,
    )


def _load_soft_source(name: str) -> Image.Image:
    """Load a VFX source without destroying its authored translucent edge."""
    path = SOURCE_DIR / name
    if not path.is_file():
        raise FileNotFoundError(path)
    rgba = Image.open(path).convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= SLASH_ALPHA_FLOOR:
                pixels[x, y] = (0, 0, 0, 0)
    return rgba


def _harden_slash_alpha(image: Image.Image) -> Image.Image:
    """Restore a crisp cutting core while retaining one soft antialias band."""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    alpha_range = float(
        SLASH_ALPHA_OPAQUE_POINT - SLASH_ALPHA_TRANSPARENT_POINT
    )
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            normalized = min(
                max(
                    (alpha - SLASH_ALPHA_TRANSPARENT_POINT) / alpha_range,
                    0.0,
                ),
                1.0,
            )
            smooth_alpha = normalized * normalized * (3.0 - 2.0 * normalized)
            hardened_alpha = round(smooth_alpha * 255.0)
            if hardened_alpha <= SLASH_ALPHA_FLOOR:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, hardened_alpha)
    return rgba


def _connected_components(
    image: Image.Image,
    alpha_threshold: int = 1,
) -> list[Component]:
    alpha = image.getchannel("A")
    width, height = image.size
    alpha_bytes = alpha.tobytes()
    remaining = bytearray(value >= alpha_threshold for value in alpha_bytes)
    components: list[Component] = []

    for start_index in range(width * height):
        if remaining[start_index] == 0:
            continue
        remaining[start_index] = 0
        stack = [start_index]
        count = 0
        sum_x = 0
        sum_y = 0
        minimum_x = width
        minimum_y = height
        maximum_x = 0
        maximum_y = 0

        while stack:
            index = stack.pop()
            y, x = divmod(index, width)
            count += 1
            sum_x += x
            sum_y += y
            minimum_x = min(minimum_x, x)
            minimum_y = min(minimum_y, y)
            maximum_x = max(maximum_x, x)
            maximum_y = max(maximum_y, y)

            if x > 0:
                neighbor = index - 1
                if remaining[neighbor]:
                    remaining[neighbor] = 0
                    stack.append(neighbor)
            if x + 1 < width:
                neighbor = index + 1
                if remaining[neighbor]:
                    remaining[neighbor] = 0
                    stack.append(neighbor)
            if y > 0:
                neighbor = index - width
                if remaining[neighbor]:
                    remaining[neighbor] = 0
                    stack.append(neighbor)
            if y + 1 < height:
                neighbor = index + width
                if remaining[neighbor]:
                    remaining[neighbor] = 0
                    stack.append(neighbor)

        components.append(
            Component(
                bbox=(minimum_x, minimum_y, maximum_x + 1, maximum_y + 1),
                size=count,
                center_x=sum_x / count,
                center_y=sum_y / count,
            )
        )

    return sorted(components, key=lambda component: component.size, reverse=True)


def _character_grid(
    image: Image.Image,
    columns: int,
    rows: int,
) -> list[list[Component]]:
    expected = columns * rows
    components = _connected_components(image)
    authored = [component for component in components if component.size >= 1000]
    if len(authored) != expected:
        raise AssertionError(
            f"Expected {expected} authored character frames, found {len(authored)}"
        )
    authored.sort(key=lambda component: component.center_y)
    grid: list[list[Component]] = []
    for row in range(rows):
        row_components = authored[row * columns : (row + 1) * columns]
        row_components.sort(key=lambda component: component.center_x)
        grid.append(row_components)
    return grid


def _component_crop(image: Image.Image, component: Component) -> Image.Image:
    return image.crop(component.bbox)


def _resize_component(image: Image.Image, scale: float) -> Image.Image:
    width = max(1, round(image.width * scale))
    height = max(1, round(image.height * scale))
    resized = image.resize((width, height), Image.Resampling.BOX)
    return _binary_alpha(resized)


def _binary_alpha(image: Image.Image, threshold: int = 52) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha < threshold:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return rgba


def _remove_neutral_frame_lines(image: Image.Image) -> Image.Image:
    """Discard the white panel dividers occasionally added by imagegen.

    Pale dust remains because it is warm/yellow rather than neutral white.
    """
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                continue
            if min(red, green, blue) >= 232 and max(red, green, blue) - min(red, green, blue) <= 18:
                pixels[x, y] = (0, 0, 0, 0)
    return rgba


def _place_centered_on_baseline(
    frame: Image.Image,
    baseline: int,
    canvas_size: int = FRAME_SIZE,
) -> Image.Image:
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    offset_x = round((canvas_size - frame.width) * 0.5)
    offset_y = baseline - frame.height + 1
    canvas.alpha_composite(frame, (offset_x, offset_y))
    return canvas


def _horizontal_authored_groups(
    image: Image.Image,
    count: int,
    minimum_main_size: int,
) -> list[Image.Image]:
    """Split a one-row board using its largest subject in each authored panel."""
    main_components = [
        component
        for component in _connected_components(image, ALPHA_THRESHOLD)
        if component.size >= minimum_main_size
    ]
    if len(main_components) != count:
        raise AssertionError(
            f"Expected {count} main authored groups, found {len(main_components)}"
        )
    main_components.sort(key=lambda component: component.center_x)
    boundaries = [0]
    boundaries.extend(
        round((left.center_x + right.center_x) * 0.5)
        for left, right in zip(main_components, main_components[1:])
    )
    boundaries.append(image.width)

    groups: list[Image.Image] = []
    for index in range(count):
        panel = image.crop((boundaries[index], 0, boundaries[index + 1], image.height))
        bbox = panel.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError(f"Authored group {index} is empty")
        groups.append(panel.crop(bbox))
    return groups


def _light_head_center(image: Image.Image) -> tuple[float, float]:
    rgba = image.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    source = rgba.load()
    target = mask.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source[x, y]
            is_warm_light = (
                alpha > 0
                and red >= 175
                and green >= 120
                and red >= blue + 28
                and green >= blue + 8
            )
            if is_warm_light:
                target[x, y] = 255

    mask_rgba = Image.new("RGBA", mask.size, (255, 255, 255, 0))
    mask_rgba.putalpha(mask)
    candidates = [
        component
        for component in _connected_components(mask_rgba)
        if component.size >= 3
    ]
    if not candidates:
        bbox = rgba.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError("Cannot register an empty frame")
        return ((bbox[0] + bbox[2] - 1) * 0.5, (bbox[1] + bbox[3] - 1) * 0.5)

    upper_candidates = [
        component
        for component in candidates
        if component.center_y <= rgba.height * 0.65
    ]
    head = max(upper_candidates or candidates, key=lambda component: component.size)
    return (head.center_x, head.center_y)


def _place_by_head(
    frame: Image.Image,
    target_head: tuple[float, float],
    canvas_size: int = FRAME_SIZE,
) -> Image.Image:
    head_x, head_y = _light_head_center(frame)
    target_x, target_y = target_head
    offset_x = round(target_x - head_x)
    offset_y = round(target_y - head_y)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    canvas.alpha_composite(frame, (offset_x, offset_y))
    return canvas


def _place_on_baseline(
    frame: Image.Image,
    baseline: int,
    target_head_x: float = 16.0,
) -> Image.Image:
    head_x, _head_y = _light_head_center(frame)
    offset_x = round(target_head_x - head_x)
    offset_y = baseline - frame.height + 1
    canvas = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(frame, (offset_x, offset_y))
    return canvas


def _paste_frame(
    sheet: Image.Image,
    frame: Image.Image,
    column: int,
    row: int,
    frame_size: int,
) -> None:
    sheet.alpha_composite(frame, (column * frame_size, row * frame_size))


def _build_character_sheets() -> tuple[Image.Image, Image.Image, Image.Image, Image.Image]:
    movement_source = _load_source("movement_alpha.png")
    attack_source = _load_source("attack_alpha.png")
    spin_source = _load_source("whirlwind_body_alpha.png")
    death_source = _load_source("death_alpha.png")
    movement_grid = _character_grid(movement_source, 4, 3)
    attack_grid = _character_grid(attack_source, 5, 3)
    spin_grid = _character_grid(spin_source, 4, 2)

    movement_components = [component for row in movement_grid for component in row]
    maximum_width = max(component.bbox[2] - component.bbox[0] for component in movement_components)
    maximum_height = max(component.bbox[3] - component.bbox[1] for component in movement_components)
    # The carried tool may extend the silhouette, but the resulting body mass
    # must stay in Weishidaier's native 16-18 x 18-21 px range.
    common_scale = min(19.0 / maximum_width, 20.0 / maximum_height)

    movement = Image.new(
        "RGBA",
        (MOVE_COLUMNS * FRAME_SIZE, MOVE_ROWS * FRAME_SIZE),
        (0, 0, 0, 0),
    )
    neutral_head_targets: list[tuple[float, float]] = []
    # The authored root is the player's feet. Keep the body above the UI bars
    # and retain the one-pixel directional posture difference.
    baselines = (25, 24, 24)
    source_order = (0, 1, 0, 3)
    placed_right_frames: list[Image.Image] = []

    for row in range(3):
        placed_row: list[Image.Image] = []
        for column, source_column in enumerate(source_order):
            crop = _component_crop(movement_source, movement_grid[row][source_column])
            resized = _resize_component(crop, common_scale)
            placed = _place_on_baseline(resized, baselines[row])
            _paste_frame(movement, placed, column, row, FRAME_SIZE)
            placed_row.append(placed)
        neutral_head_targets.append(_light_head_center(placed_row[0]))
        if row == 2:
            placed_right_frames = placed_row

    for column, right_frame in enumerate(placed_right_frames):
        left_frame = right_frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        _paste_frame(movement, left_frame, column, 3, FRAME_SIZE)

    attack = Image.new(
        "RGBA",
        (ATTACK_COLUMNS * FRAME_SIZE, ATTACK_ROWS * FRAME_SIZE),
        (0, 0, 0, 0),
    )
    phase_offsets = ((0.0, 0.0), (0.0, 0.0), (0.0, 0.0), (1.0, 0.0), (0.0, 0.0))
    placed_attack_right: list[Image.Image] = []
    for row in range(3):
        for column, component in enumerate(attack_grid[row]):
            crop = _component_crop(attack_source, component)
            resized = _resize_component(crop, common_scale)
            base_head_x, base_head_y = neutral_head_targets[row]
            phase_x, phase_y = phase_offsets[column]
            placed = _place_by_head(
                resized,
                (base_head_x + phase_x, base_head_y + phase_y),
            )
            _paste_frame(attack, placed, column, row, FRAME_SIZE)
            if row == 2:
                placed_attack_right.append(placed)

    for column, right_frame in enumerate(placed_attack_right):
        left_frame = right_frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        _paste_frame(attack, left_frame, column, 3, FRAME_SIZE)

    spin = Image.new("RGBA", (8 * FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    spin_components = [component for row in spin_grid for component in row]
    # Imagegen authored the spin board about 16% larger than the walk board.
    # Apply one board-wide correction so the cat body does not grow during the
    # skill; every spin frame still shares exactly the same scale.
    spin_scale = common_scale * 0.86
    spin_offsets = ((0.0, 0.0), (0.0, 0.0), (0.0, -1.0), (0.0, -1.0),
                    (0.0, 0.0), (0.0, 0.0), (0.0, -1.0), (0.0, 0.0))
    target_spin_head = neutral_head_targets[0]
    for index, component in enumerate(spin_components):
        crop = _component_crop(spin_source, component)
        resized = _resize_component(crop, spin_scale)
        offset_x, offset_y = spin_offsets[index]
        placed = _place_by_head(
            resized,
            (target_spin_head[0] + offset_x, target_spin_head[1] + offset_y),
        )
        _paste_frame(spin, placed, index, 0, FRAME_SIZE)

    death = Image.new(
        "RGBA",
        (DEATH_COLUMNS * FRAME_SIZE, FRAME_SIZE),
        (0, 0, 0, 0),
    )
    # This board was authored at a larger presentation scale than the motion
    # boards. One shared correction preserves the cat's mass across all five
    # collapse poses instead of normalizing each pose independently.
    death_scale = common_scale * 0.80
    death_groups = _horizontal_authored_groups(
        death_source,
        DEATH_COLUMNS,
        minimum_main_size=30000,
    )
    for column, group in enumerate(death_groups):
        resized = _resize_component(group, death_scale)
        placed = _place_centered_on_baseline(resized, baseline=25)
        _paste_frame(death, placed, column, 0, FRAME_SIZE)

    palette = _build_palette([movement], 16)
    movement = _reinforce_character_edges(_map_to_palette(movement, palette), palette)
    attack = _reinforce_character_edges(_map_to_palette(attack, palette), palette)
    spin = _reinforce_character_edges(_map_to_palette(spin, palette), palette)
    death = _reinforce_character_edges(_map_to_palette(death, palette), palette)
    print(f"Character source common scale: {common_scale:.5f}")
    return movement, attack, spin, death


def _crop_centered_square(
    image: Image.Image,
    center_x: float,
    center_y: float,
    side: int,
    bounds: tuple[int, int, int, int],
) -> Image.Image:
    left = round(center_x - side * 0.5)
    top = round(center_y - side * 0.5)
    right = left + side
    bottom = top + side
    bound_left, bound_top, bound_right, bound_bottom = bounds
    source_left = max(left, bound_left, 0)
    source_top = max(top, bound_top, 0)
    source_right = min(right, bound_right, image.width)
    source_bottom = min(bottom, bound_bottom, image.height)
    output = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    crop = image.crop((source_left, source_top, source_right, source_bottom))
    output.alpha_composite(crop, (source_left - left, source_top - top))
    return output


def _split_uniform_source_grid(
    source: Image.Image,
    columns: int,
    rows: int,
) -> list[Image.Image]:
    panels: list[Image.Image] = []
    for row in range(rows):
        top = round(row * source.height / rows)
        bottom = round((row + 1) * source.height / rows)
        for column in range(columns):
            left = round(column * source.width / columns)
            right = round((column + 1) * source.width / columns)
            panels.append(source.crop((left, top, right, bottom)))
    return panels


def _detect_shared_sector_pivot(
    panels: list[Image.Image],
    peak_indices: tuple[int, ...],
) -> tuple[float, float]:
    """Register every frame to one stable pivot from the two full crescents."""
    pivot_x_values: list[float] = []
    pivot_y_values: list[float] = []
    for index in peak_indices:
        components = _connected_components(panels[index], ALPHA_THRESHOLD)
        if not components:
            raise AssertionError(f"Slash peak panel {index} is empty")
        main_component = components[0]
        left, top, _right, bottom = main_component.bbox
        pivot_x_values.append(float(left))
        pivot_y_values.append((top + bottom - 1) * 0.5)
    return (
        sum(pivot_x_values) / len(pivot_x_values),
        sum(pivot_y_values) / len(pivot_y_values),
    )


def _forward_radius_percentile(
    panel: Image.Image,
    pivot: tuple[float, float],
    percentile: float = 0.99,
) -> float:
    pivot_x, pivot_y = pivot
    radii: list[float] = []
    alpha = panel.convert("RGBA").getchannel("A")
    for y in range(panel.height):
        for x in range(panel.width):
            if alpha.getpixel((x, y)) <= ALPHA_THRESHOLD:
                continue
            delta_x = (x + 0.5) - pivot_x
            delta_y = (y + 0.5) - pivot_y
            if delta_x <= 0.0:
                continue
            angle = abs(math.degrees(math.atan2(delta_y, delta_x)))
            if angle <= 30.0:
                radii.append(math.hypot(delta_x, delta_y))
    if not radii:
        raise AssertionError("Authored slash panel has no pixels in the forward sector")
    radii.sort()
    index = round((len(radii) - 1) * percentile)
    return radii[index]


def _build_basic_slash_sheet() -> Image.Image:
    slash_source = _load_soft_source("basic_slash_vfx_flow_v3_alpha.png")
    panels = _split_uniform_source_grid(
        slash_source,
        SLASH_SOURCE_COLUMNS,
        SLASH_SOURCE_ROWS,
    )
    if len(panels) != SLASH_FRAME_COUNT:
        raise AssertionError(f"Expected {SLASH_FRAME_COUNT} slash panels")
    pivot = _detect_shared_sector_pivot(panels, SLASH_PEAK_FRAME_INDICES)
    authored_radius = max(
        _forward_radius_percentile(panels[index], pivot)
        for index in SLASH_PEAK_FRAME_INDICES
    )
    radial_scale = SLASH_ATTACK_RADIUS / authored_radius
    cross_axis_scale = radial_scale * SLASH_CROSS_AXIS_SCALE
    slash = Image.new(
        "RGBA",
        (SLASH_FRAME_COUNT * SLASH_FRAME_SIZE, SLASH_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    for frame_index, panel in enumerate(panels):
        resized = panel.resize(
            (
                max(1, round(panel.width * radial_scale)),
                max(1, round(panel.height * cross_axis_scale)),
            ),
            Image.Resampling.LANCZOS,
        )
        frame = Image.new(
            "RGBA",
            (SLASH_FRAME_SIZE, SLASH_FRAME_SIZE),
            (0, 0, 0, 0),
        )
        frame.alpha_composite(
            resized,
            (
                round(SLASH_FRAME_SIZE * 0.5 - pivot[0] * radial_scale),
                round(SLASH_FRAME_SIZE * 0.5 - pivot[1] * cross_axis_scale),
            ),
        )
        _paste_frame(slash, frame, frame_index, 0, SLASH_FRAME_SIZE)
        print(
            f"Slash frame {frame_index}: pivot=({pivot[0]:.2f},{pivot[1]:.2f}) "
            f"authored_radius={authored_radius:.2f} "
            f"radial_scale={radial_scale:.4f} cross_scale={cross_axis_scale:.4f}"
        )
    slash = _harden_slash_alpha(slash)
    return _map_to_palette_preserve_alpha(slash, SLASH_PALETTE)


def _build_whirlwind_icon() -> Image.Image:
    source = _load_source("whirlwind_icon_v2_alpha.png")
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Whirlwind icon source is empty")
    subject = source.crop(bbox)
    scale = min(
        WHIRLWIND_ICON_SUBJECT_SIZE / subject.width,
        WHIRLWIND_ICON_SUBJECT_SIZE / subject.height,
    )
    resized = _binary_alpha(
        subject.resize(
            (
                max(1, round(subject.width * scale)),
                max(1, round(subject.height * scale)),
            ),
            Image.Resampling.BOX,
        ),
        threshold=16,
    )
    icon = Image.new(
        "RGBA",
        (WHIRLWIND_ICON_SIZE, WHIRLWIND_ICON_SIZE),
        (0, 0, 0, 0),
    )
    icon.alpha_composite(
        resized,
        (
            (WHIRLWIND_ICON_SIZE - resized.width) // 2,
            (WHIRLWIND_ICON_SIZE - resized.height) // 2,
        ),
    )
    return _map_to_palette(icon, WHIRLWIND_ICON_PALETTE)


def _build_whirlwind_vfx_sheet() -> Image.Image:
    whirlwind_source = _load_source("whirlwind_vfx_alpha.png")

    whirlwind = Image.new(
        "RGBA",
        (8 * WHIRLWIND_VFX_FRAME_SIZE, WHIRLWIND_VFX_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    source_cell_width = whirlwind_source.width / 4.0
    source_row_centers = (294.0, 720.0)
    for row in range(2):
        for column in range(4):
            left = round(column * source_cell_width)
            right = round((column + 1) * source_cell_width)
            row_top = 0 if row == 0 else round((source_row_centers[0] + source_row_centers[1]) * 0.5)
            row_bottom = round((source_row_centers[0] + source_row_centers[1]) * 0.5) if row == 0 else whirlwind_source.height
            square = _crop_centered_square(
                whirlwind_source,
                (left + right) * 0.5,
                source_row_centers[row],
                336,
                (left, row_top, right, row_bottom),
            )
            frame = _binary_alpha(
                square.resize(
                    (WHIRLWIND_VFX_FRAME_SIZE, WHIRLWIND_VFX_FRAME_SIZE),
                    Image.Resampling.BOX,
                )
            )
            _paste_frame(
                whirlwind,
                frame,
                row * 4 + column,
                0,
                WHIRLWIND_VFX_FRAME_SIZE,
            )

    return _map_to_palette(whirlwind, VFX_PALETTE)


def _build_vfx_sheets() -> tuple[Image.Image, Image.Image]:
    return _build_basic_slash_sheet(), _build_whirlwind_vfx_sheet()


def _build_palette(images: list[Image.Image], colors: int) -> list[tuple[int, int, int]]:
    opaque_colors: list[tuple[int, int, int]] = []
    for image in images:
        opaque_colors.extend(
            pixel[:3]
            for pixel in image.convert("RGBA").getdata()
            if pixel[3] > 0
        )
    if not opaque_colors:
        raise AssertionError("Cannot build a palette from empty images")
    strip = Image.new("RGB", (len(opaque_colors), 1))
    strip.putdata(opaque_colors)
    quantized = strip.quantize(
        colors=min(colors, len(set(opaque_colors))),
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")
    palette = sorted(set(quantized.getdata()), key=lambda color: sum(color))
    return palette


def _map_to_palette(
    image: Image.Image,
    palette: list[tuple[int, int, int]],
) -> Image.Image:
    rgba = _binary_alpha(image)
    pixels = rgba.load()
    cache: dict[tuple[int, int, int], tuple[int, int, int]] = {}
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            source_color = (red, green, blue)
            mapped = cache.get(source_color)
            if mapped is None:
                mapped = min(
                    palette,
                    key=lambda color: (
                        (source_color[0] - color[0]) ** 2
                        + (source_color[1] - color[1]) ** 2
                        + (source_color[2] - color[2]) ** 2
                    ),
                )
                cache[source_color] = mapped
            pixels[x, y] = (*mapped, 255)
    return rgba


def _map_to_palette_preserve_alpha(
    image: Image.Image,
    palette: list[tuple[int, int, int]],
) -> Image.Image:
    """Quantize VFX colour while retaining its soft authored silhouette."""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    cache: dict[tuple[int, int, int], tuple[int, int, int]] = {}
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= SLASH_ALPHA_FLOOR:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            source_color = (red, green, blue)
            mapped = cache.get(source_color)
            if mapped is None:
                mapped = min(
                    palette,
                    key=lambda color: (
                        (source_color[0] - color[0]) ** 2
                        + (source_color[1] - color[1]) ** 2
                        + (source_color[2] - color[2]) ** 2
                    ),
                )
                cache[source_color] = mapped
            pixels[x, y] = (*mapped, alpha)
    return rgba


def _reinforce_character_edges(
    image: Image.Image,
    palette: list[tuple[int, int, int]],
) -> Image.Image:
    """Give the downscaled body a native one-pixel outline and crisp dark details."""
    rgba = image.convert("RGBA")
    source = rgba.copy()
    source_pixels = source.load()
    target_pixels = rgba.load()
    darkest = min(
        palette,
        key=lambda color: 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2],
    )
    neighbors = (
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
    )
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source_pixels[x, y]
            if alpha == 0:
                continue
            is_boundary = any(
                x + delta_x < 0
                or x + delta_x >= rgba.width
                or y + delta_y < 0
                or y + delta_y >= rgba.height
                or source_pixels[x + delta_x, y + delta_y][3] == 0
                for delta_x, delta_y in neighbors
            )
            luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            if is_boundary or luminance <= 68.0:
                target_pixels[x, y] = (*darkest, 255)
    return rgba


def _save_portrait(movement: Image.Image) -> None:
    front = movement.crop((0, 0, FRAME_SIZE, FRAME_SIZE))
    bbox = front.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Cannot create a portrait from an empty front frame")
    subject = front.crop(bbox)
    portrait_scale = 6
    enlarged = subject.resize(
        (subject.width * portrait_scale, subject.height * portrait_scale),
        Image.Resampling.NEAREST,
    )
    if enlarged.width > 128 or enlarged.height > 128:
        raise AssertionError(
            f"Portrait subject {enlarged.size} exceeds the 128x128 canvas"
        )
    portrait = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    portrait.alpha_composite(
        enlarged,
        ((128 - enlarged.width) // 2, (128 - enlarged.height) // 2),
    )
    portrait.save(OUTPUT_DIR / "portrait.png", optimize=True)


def _checkerboard(size: tuple[int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size, (36, 40, 48, 255))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            if (x // 8 + y // 8) % 2:
                pixels[x, y] = (54, 59, 68, 255)
    return image


def _save_preview(images: list[Image.Image]) -> None:
    widths = [image.width for image in images]
    width = max(widths)
    height = sum(image.height for image in images) + (len(images) - 1) * 8
    preview = _checkerboard((width, height))
    y = 0
    for image in images:
        preview.alpha_composite(image, (0, y))
        y += image.height + 8
    PREVIEW_PATH.parent.mkdir(parents=True, exist_ok=True)
    preview.resize(
        (preview.width * 4, preview.height * 4),
        Image.Resampling.NEAREST,
    ).save(PREVIEW_PATH, optimize=True)


def _report_grid(name: str, image: Image.Image) -> None:
    analysis = analyze_image(image)
    print(
        f"{name}: {image.width}x{image.height}, "
        f"grid={analysis['detection_mode']} "
        f"{analysis['grid_cell_width']}x{analysis['grid_cell_height']}"
    )


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    movement, attack, spin, death = _build_character_sheets()
    slash, whirlwind = _build_vfx_sheets()
    whirlwind_icon = _build_whirlwind_icon()
    outputs = {
        "hoe_cat_move.png": movement,
        "hoe_cat_attack.png": attack,
        "hoe_cat_whirlwind_body.png": spin,
        "hoe_cat_death.png": death,
        "hoe_cat_basic_slash_vfx.png": slash,
        "hoe_cat_whirlwind_vfx.png": whirlwind,
        "whirlwind_icon.png": whirlwind_icon,
    }
    for name, image in outputs.items():
        image.save(OUTPUT_DIR / name, optimize=True)
        _report_grid(name, image)
    _save_portrait(movement)
    _save_preview([movement, attack, spin, death, slash, whirlwind, whirlwind_icon])
    print(f"Saved preview: {PREVIEW_PATH}")


def main_slash_only() -> None:
    """Rebuild only the primary slash without touching user-edited body sheets."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    slash = _build_basic_slash_sheet()
    slash.save(OUTPUT_DIR / "hoe_cat_basic_slash_vfx.png", optimize=True)
    _report_grid("hoe_cat_basic_slash_vfx.png", slash)


def main_portrait_only() -> None:
    """Rebuild the UI portrait from the current runtime movement sheet."""
    movement_path = OUTPUT_DIR / "hoe_cat_move.png"
    if not movement_path.is_file():
        raise FileNotFoundError(movement_path)
    _save_portrait(Image.open(movement_path).convert("RGBA"))
    _report_grid("portrait.png", Image.open(OUTPUT_DIR / "portrait.png"))


def main_icon_only() -> None:
    """Rebuild only the missing skill icon without touching body sheets."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    icon = _build_whirlwind_icon()
    icon.save(OUTPUT_DIR / "whirlwind_icon.png", optimize=True)
    _report_grid("whirlwind_icon.png", icon)


if __name__ == "__main__":
    requested_mode = sys.argv[1] if len(sys.argv) > 1 else "--all"
    if requested_mode == "--slash-only":
        main_slash_only()
    elif requested_mode == "--portrait-only":
        main_portrait_only()
    elif requested_mode == "--icon-only":
        main_icon_only()
    elif requested_mode == "--all":
        main()
    else:
        raise SystemExit(
            "Usage: process_hoe_cat_assets.py "
            "[--all|--slash-only|--portrait-only|--icon-only]"
        )
