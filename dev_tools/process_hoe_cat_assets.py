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
FRAME_SIZE = 32
SLASH_FRAME_SIZE = 32
WHIRLWIND_VFX_FRAME_SIZE = 48
ALPHA_THRESHOLD = 56


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


def _build_character_sheets() -> tuple[Image.Image, Image.Image, Image.Image]:
    movement_source = _load_source("movement_alpha.png")
    attack_source = _load_source("attack_alpha.png")
    spin_source = _load_source("whirlwind_body_alpha.png")
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
    baselines = (27, 25, 25)
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

    palette = _build_palette([movement], 16)
    movement = _map_to_palette(movement, palette)
    attack = _map_to_palette(attack, palette)
    spin = _map_to_palette(spin, palette)
    print(f"Character source common scale: {common_scale:.5f}")
    return movement, attack, spin


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


def _build_vfx_sheets() -> tuple[Image.Image, Image.Image]:
    slash_source = _load_source("basic_slash_vfx_alpha.png")
    whirlwind_source = _load_source("whirlwind_vfx_alpha.png")

    slash = Image.new(
        "RGBA",
        (5 * SLASH_FRAME_SIZE, SLASH_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    slash_cell_width = slash_source.width / 5.0
    for column in range(5):
        left = round(column * slash_cell_width)
        right = round((column + 1) * slash_cell_width)
        square = _crop_centered_square(
            slash_source,
            (left + right) * 0.5,
            slash_source.height * 0.5,
            384,
            (left, 0, right, slash_source.height),
        )
        frame = _binary_alpha(
            square.resize(
                (SLASH_FRAME_SIZE, SLASH_FRAME_SIZE),
                Image.Resampling.BOX,
            )
        )
        # The generated crescent is centered around its own circular guide.
        # Runtime rotates the texture around the player, so translate the authored
        # trail into the forward/right half of the logical cell before rotation.
        forward_frame = Image.new(
            "RGBA",
            (SLASH_FRAME_SIZE, SLASH_FRAME_SIZE),
            (0, 0, 0, 0),
        )
        forward_frame.alpha_composite(frame, (7, 0))
        frame = forward_frame
        _paste_frame(slash, frame, column, 0, SLASH_FRAME_SIZE)

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

    palette = _build_palette([slash, whirlwind], 8)
    return _map_to_palette(slash, palette), _map_to_palette(whirlwind, palette)


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


def _save_portrait(movement: Image.Image) -> None:
    front = movement.crop((0, 0, FRAME_SIZE, FRAME_SIZE))
    portrait = front.resize((128, 128), Image.Resampling.NEAREST)
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
    movement, attack, spin = _build_character_sheets()
    slash, whirlwind = _build_vfx_sheets()
    outputs = {
        "hoe_cat_move.png": movement,
        "hoe_cat_attack.png": attack,
        "hoe_cat_whirlwind_body.png": spin,
        "hoe_cat_basic_slash_vfx.png": slash,
        "hoe_cat_whirlwind_vfx.png": whirlwind,
    }
    for name, image in outputs.items():
        image.save(OUTPUT_DIR / name, optimize=True)
        _report_grid(name, image)
    _save_portrait(movement)
    _save_preview([movement, attack, spin, slash, whirlwind])
    print(f"Saved preview: {PREVIEW_PATH}")


if __name__ == "__main__":
    main()
