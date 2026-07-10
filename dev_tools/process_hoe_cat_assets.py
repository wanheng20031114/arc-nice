#!/usr/bin/env python3
"""Build the runtime Hoe Cat pixel sheets from image-generation alpha sources."""

from __future__ import annotations

from math import hypot
from pathlib import Path
import sys

from PIL import Image

sys.dont_write_bytecode = True
from pixel_crop_tool import compress_to_logical_grid, crop_to_square, normalize_transparency


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "hoe_cat"
OUTPUT_DIR = ROOT / "resources" / "texture" / "player" / "hoe_cat"
WEISHIDAIER_DIR = ROOT / "resources" / "texture" / "player" / "weishidaier"


def _clean_and_quantize(image: Image.Image, colors: int = 32) -> Image.Image:
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A").point(lambda value: 255 if value >= 32 else 0)
    quantized = rgba.quantize(
        colors=colors,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.NONE,
    ).convert("RGBA")
    quantized.putalpha(alpha)
    pixels = quantized.load()
    for y in range(quantized.height):
        for x in range(quantized.width):
            if pixels[x, y][3] == 0:
                pixels[x, y] = (0, 0, 0, 0)
    return quantized


def _split_cells(image: Image.Image, columns: int, rows: int) -> list[list[Image.Image]]:
    cells: list[list[Image.Image]] = []
    for row in range(rows):
        row_cells: list[Image.Image] = []
        top = round(row * image.height / rows)
        bottom = round((row + 1) * image.height / rows)
        for column in range(columns):
            left = round(column * image.width / columns)
            right = round((column + 1) * image.width / columns)
            row_cells.append(image.crop((left, top, right, bottom)))
        cells.append(row_cells)
    return cells


def _alpha_components(image: Image.Image) -> list[list[tuple[int, int]]]:
    pixels = image.load()
    visited: set[tuple[int, int]] = set()
    components: list[list[tuple[int, int]]] = []
    for y in range(image.height):
        for x in range(image.width):
            if pixels[x, y][3] == 0 or (x, y) in visited:
                continue
            stack = [(x, y)]
            visited.add((x, y))
            component: list[tuple[int, int]] = []
            while stack:
                current_x, current_y = stack.pop()
                component.append((current_x, current_y))
                for neighbor_y in range(current_y - 1, current_y + 2):
                    for neighbor_x in range(current_x - 1, current_x + 2):
                        neighbor = (neighbor_x, neighbor_y)
                        if (
                            0 <= neighbor_x < image.width
                            and 0 <= neighbor_y < image.height
                            and neighbor not in visited
                            and pixels[neighbor_x, neighbor_y][3] > 0
                        ):
                            visited.add(neighbor)
                            stack.append(neighbor)
            components.append(component)
    return sorted(components, key=len, reverse=True)


def _drop_small_components(image: Image.Image, minimum_pixels: int) -> Image.Image:
    if minimum_pixels <= 1:
        return image
    pixels = image.load()
    for component in _alpha_components(image):
        if len(component) >= minimum_pixels:
            continue
        for x, y in component:
            pixels[x, y] = (0, 0, 0, 0)
    return image


def _draw_pixel_line(
    image: Image.Image,
    start: tuple[int, int],
    end: tuple[int, int],
    color: tuple[int, int, int, int],
) -> None:
    pixels = image.load()
    x0, y0 = start
    x1, y1 = end
    delta_x = abs(x1 - x0)
    step_x = 1 if x0 < x1 else -1
    delta_y = -abs(y1 - y0)
    step_y = 1 if y0 < y1 else -1
    error = delta_x + delta_y
    while True:
        pixels[x0, y0] = color
        if x0 == x1 and y0 == y1:
            return
        doubled_error = error * 2
        if doubled_error >= delta_y:
            error += delta_y
            x0 += step_x
        if doubled_error <= delta_x:
            error += delta_x
            y0 += step_y


def _connect_nearby_components(
    image: Image.Image,
    maximum_distance: float = 6.0,
    bridge_color: tuple[int, int, int, int] = (137, 72, 25, 255),
) -> Image.Image:
    components = _alpha_components(image)
    if len(components) <= 1:
        return image
    main_component = list(components[0])
    for component in components[1:]:
        distance, main_point, component_point = min(
            (
                hypot(main_x - component_x, main_y - component_y),
                (main_x, main_y),
                (component_x, component_y),
            )
            for main_x, main_y in main_component
            for component_x, component_y in component
        )
        if distance > maximum_distance:
            continue
        _draw_pixel_line(image, main_point, component_point, bridge_color)
        main_component.extend(component)
    return image


def _extract_palette(*images: Image.Image) -> list[tuple[int, int, int]]:
    colors: set[tuple[int, int, int]] = set()
    for image in images:
        colors.update(pixel[:3] for pixel in image.getdata() if pixel[3] > 0)
    return sorted(colors)


def _remap_to_palette(
    image: Image.Image,
    palette: list[tuple[int, int, int]],
) -> Image.Image:
    if not palette:
        return image
    pixels = image.load()
    color_cache: dict[tuple[int, int, int], tuple[int, int, int]] = {}
    for y in range(image.height):
        for x in range(image.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                continue
            source_color = (red, green, blue)
            target_color = color_cache.get(source_color)
            if target_color is None:
                target_color = min(
                    palette,
                    key=lambda color: (
                        (color[0] - red) ** 2
                        + (color[1] - green) ** 2
                        + (color[2] - blue) ** 2
                    ),
                )
                color_cache[source_color] = target_color
            pixels[x, y] = (*target_color, 255)
    return image


def _fit_sheet(
    source_name: str,
    output_name: str,
    columns: int,
    rows: int,
    cell_size: tuple[int, int],
    subject_limit: tuple[int, int],
    row_order: tuple[int, ...] | None = None,
    baseline_pixel: int | None = None,
    minimum_component_pixels: int = 0,
    frame_offsets: dict[tuple[int, int], tuple[int, int]] | None = None,
    palette: list[tuple[int, int, int]] | None = None,
) -> Image.Image:
    source = _clean_and_quantize(Image.open(SOURCE_DIR / source_name))
    cells = _split_cells(source, columns, rows)
    if row_order is not None:
        cells = [cells[index] for index in row_order]

    bboxes: list[tuple[int, int, int, int]] = []
    flat_cells = [cell for row_cells in cells for cell in row_cells]
    for cell in flat_cells:
        bbox = cell.getchannel("A").getbbox()
        if bbox is None:
            bbox = (0, 0, 1, 1)
        bboxes.append(bbox)

    max_width = max(bbox[2] - bbox[0] for bbox in bboxes)
    max_height = max(bbox[3] - bbox[1] for bbox in bboxes)
    common_scale = min(
        subject_limit[0] / max(max_width, 1),
        subject_limit[1] / max(max_height, 1),
    )

    output = Image.new(
        "RGBA",
        (cell_size[0] * columns, cell_size[1] * rows),
        (0, 0, 0, 0),
    )
    for index, (cell, bbox) in enumerate(zip(flat_cells, bboxes)):
        cropped = cell.crop(bbox)
        target_width = max(1, round(cropped.width * common_scale))
        target_height = max(1, round(cropped.height * common_scale))
        resized = cropped.resize(
            (target_width, target_height),
            Image.Resampling.NEAREST,
        )
        resized = _drop_small_components(resized, minimum_component_pixels)
        clean_bbox = resized.getchannel("A").getbbox()
        if clean_bbox is not None:
            resized = resized.crop(clean_bbox)
        resized = _remap_to_palette(resized, palette or [])
        target_width, target_height = resized.size
        row = index // columns
        column = index % columns
        offset_x, offset_y = (frame_offsets or {}).get((row, column), (0, 0))
        target_x = (
            column * cell_size[0]
            + (cell_size[0] - target_width) // 2
            + offset_x
        )
        if baseline_pixel is not None:
            target_y = (
                row * cell_size[1]
                + baseline_pixel
                - target_height
                + 1
                + offset_y
            )
        else:
            target_y = (
                row * cell_size[1]
                + (cell_size[1] - target_height) // 2
                + offset_y
            )
        output.alpha_composite(resized, (target_x, target_y))

    output.save(OUTPUT_DIR / output_name, optimize=True)
    return output


def _build_weishidaier_portrait() -> None:
    source = _clean_and_quantize(Image.open(WEISHIDAIER_DIR / "body.png"), colors=48)
    frame = source.crop((0, 64, 32, 96))
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Weishidaier portrait frame is empty")
    subject = frame.crop(bbox)
    scale = min(112 / subject.width, 112 / subject.height)
    resized = subject.resize(
        (max(1, round(subject.width * scale)), max(1, round(subject.height * scale))),
        Image.Resampling.NEAREST,
    )
    portrait = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    portrait.alpha_composite(
        resized,
        ((128 - resized.width) // 2, (128 - resized.height) // 2),
    )
    portrait.save(WEISHIDAIER_DIR / "portrait.png", optimize=True)


def _build_hoe_with_pixel_crop_tool() -> Image.Image:
    source = normalize_transparency(
        Image.open(SOURCE_DIR / "hoe_alpha.png"),
        alpha_threshold=31,
    )
    cropped = crop_to_square(source)
    compressed, _analysis = compress_to_logical_grid(cropped, logical_size=12)
    compressed = _clean_and_quantize(compressed, colors=24)
    canvas = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    canvas.alpha_composite(compressed, ((16 - compressed.width) // 2, (16 - compressed.height) // 2))
    canvas.save(OUTPUT_DIR / "hoe.png", optimize=True)
    return canvas


def _build_attack_sheet(
    palette: list[tuple[int, int, int]],
) -> Image.Image:
    source = _clean_and_quantize(
        Image.open(SOURCE_DIR / "hoe_cat_attack_low_pixel_v2_alpha.png")
    )
    cells = _split_cells(source, 4, 4)
    output = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    row_offsets = (-2, -1, -1, 1)
    for row, row_cells in enumerate(cells):
        for column, cell in enumerate(row_cells):
            resized = cell.resize((32, 32), Image.Resampling.NEAREST)
            resized = _drop_small_components(resized, 4)
            resized = _remap_to_palette(resized, palette)
            output.alpha_composite(
                resized,
                (column * 32, row * 32 + row_offsets[row]),
            )
    output.save(OUTPUT_DIR / "hoe_cat_attack.png", optimize=True)
    return output


def _build_whirlwind_body_sheet(
    palette: list[tuple[int, int, int]],
) -> Image.Image:
    source = _clean_and_quantize(
        Image.open(SOURCE_DIR / "hoe_cat_whirlwind_body_low_pixel_v2_alpha.png")
    )
    cells = _split_cells(source, 8, 1)[0]
    crop_top = round(source.height * 240.0 / 793.0)
    crop_bottom = round(source.height * 590.0 / 793.0)
    square_side = crop_bottom - crop_top
    output = Image.new("RGBA", (256, 32), (0, 0, 0, 0))
    for column, cell in enumerate(cells):
        cropped = cell.crop((0, crop_top, cell.width, crop_bottom))
        square = Image.new(
            "RGBA",
            (square_side, square_side),
            (0, 0, 0, 0),
        )
        square.alpha_composite(cropped, ((square_side - cropped.width) // 2, 0))
        resized = square.resize((32, 32), Image.Resampling.NEAREST)
        resized = _drop_small_components(resized, 4)
        resized = _connect_nearby_components(resized)
        subject_bbox = resized.getchannel("A").getbbox()
        if subject_bbox is None:
            continue
        subject = resized.crop(subject_bbox)
        subject = subject.resize(
            (
                max(1, round(subject.width * 0.9)),
                max(1, round(subject.height * 0.9)),
            ),
            Image.Resampling.NEAREST,
        )
        subject = _connect_nearby_components(subject)
        subject = _remap_to_palette(subject, palette)
        output.alpha_composite(
            subject,
            (
                column * 32 + (32 - subject.width) // 2,
                24 - subject.height + 1,
            ),
        )
    output.save(OUTPUT_DIR / "hoe_cat_whirlwind_body.png", optimize=True)
    return output


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    hoe = _build_hoe_with_pixel_crop_tool()
    # The runtime SpriteFrames resource expects down/up/right/left rows.
    movement = _fit_sheet(
        "hoe_cat_move_alpha.png",
        "hoe_cat_move.png",
        4,
        4,
        (32, 32),
        (24, 24),
        row_order=(1, 0, 3, 2),
        baseline_pixel=24,
        minimum_component_pixels=5,
    )
    shared_character_palette = _extract_palette(movement, hoe)
    _build_attack_sheet(shared_character_palette)
    _build_whirlwind_body_sheet(shared_character_palette)
    _fit_sheet(
        "basic_slash_vfx_alpha.png",
        "hoe_cat_basic_slash_vfx.png",
        4,
        1,
        (32, 32),
        (24, 24),
    )
    _fit_sheet(
        "whirlwind_vfx_alpha.png",
        "hoe_cat_whirlwind_vfx.png",
        8,
        1,
        (48, 48),
        (32, 32),
    )
    _fit_sheet("portrait_alpha.png", "portrait.png", 1, 1, (128, 128), (120, 120))
    _fit_sheet(
        "whirlwind_icon_alpha.png",
        "whirlwind_icon.png",
        1,
        1,
        (128, 128),
        (120, 120),
    )
    _build_weishidaier_portrait()


if __name__ == "__main__":
    main()
