#!/usr/bin/env python3
"""Build Luoxi NPC and apple collectible pixel assets from generated sources."""

from __future__ import annotations

from pathlib import Path

from PIL import Image


FRAME_COUNT = 8
OUTPUT_FRAME_SIZE = 32
LUOXI_HIGH_RES_FRAME_SIZE = 384
LUOXI_SUBJECT_HEIGHT = 30
LUOXI_MAX_SUBJECT_WIDTH = 28
LUOXI_FOOT_Y = 31
APPLE_ICON_SIZE = 32
ALPHA_THRESHOLD = 32


def _solid_alpha(image: Image.Image) -> Image.Image:
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


def _keep_largest_alpha_component(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    alpha_pixels = alpha.load()
    width, height = rgba.size
    visited: set[tuple[int, int]] = set()
    largest_component: list[tuple[int, int]] = []

    for y in range(height):
        for x in range(width):
            if alpha_pixels[x, y] <= ALPHA_THRESHOLD or (x, y) in visited:
                continue

            component: list[tuple[int, int]] = []
            stack = [(x, y)]
            visited.add((x, y))
            while stack:
                current_x, current_y = stack.pop()
                component.append((current_x, current_y))
                for next_y in range(current_y - 1, current_y + 2):
                    for next_x in range(current_x - 1, current_x + 2):
                        if (
                            next_x < 0
                            or next_y < 0
                            or next_x >= width
                            or next_y >= height
                            or (next_x, next_y) in visited
                        ):
                            continue
                        if alpha_pixels[next_x, next_y] <= ALPHA_THRESHOLD:
                            continue
                        visited.add((next_x, next_y))
                        stack.append((next_x, next_y))

            if len(component) > len(largest_component):
                largest_component = component

    if not largest_component:
        return rgba

    keep_pixels = set(largest_component)
    pixels = rgba.load()
    for y in range(height):
        for x in range(width):
            if (x, y) not in keep_pixels:
                pixels[x, y] = (0, 0, 0, 0)
    return rgba


def _visible_component_bboxes(image: Image.Image) -> list[tuple[int, int, int, int]]:
    rgba = image.convert("RGBA")
    alpha_pixels = rgba.getchannel("A").load()
    width, height = rgba.size
    visited: set[tuple[int, int]] = set()
    components: list[tuple[int, tuple[int, int, int, int]]] = []

    for y in range(height):
        for x in range(width):
            if alpha_pixels[x, y] <= ALPHA_THRESHOLD or (x, y) in visited:
                continue

            stack = [(x, y)]
            visited.add((x, y))
            min_x = max_x = x
            min_y = max_y = y
            size = 0
            while stack:
                current_x, current_y = stack.pop()
                size += 1
                min_x = min(min_x, current_x)
                max_x = max(max_x, current_x)
                min_y = min(min_y, current_y)
                max_y = max(max_y, current_y)

                for next_y in range(current_y - 1, current_y + 2):
                    for next_x in range(current_x - 1, current_x + 2):
                        if (
                            next_x < 0
                            or next_y < 0
                            or next_x >= width
                            or next_y >= height
                            or (next_x, next_y) in visited
                        ):
                            continue
                        if alpha_pixels[next_x, next_y] <= ALPHA_THRESHOLD:
                            continue
                        visited.add((next_x, next_y))
                        stack.append((next_x, next_y))

            components.append((size, (min_x, min_y, max_x + 1, max_y + 1)))

    largest = sorted(components, reverse=True)[:FRAME_COUNT]
    if len(largest) != FRAME_COUNT:
        raise ValueError(f"Expected {FRAME_COUNT} Luoxi source sprites, found {len(largest)}.")

    return [bbox for _size, bbox in sorted(largest, key=lambda item: item[1][0])]


def _build_centered_luoxi_source(source: Image.Image) -> Image.Image:
    source = _solid_alpha(source)
    source_sheet = Image.new(
        "RGBA",
        (LUOXI_HIGH_RES_FRAME_SIZE * FRAME_COUNT, LUOXI_HIGH_RES_FRAME_SIZE),
        (0, 0, 0, 0),
    )

    for frame_index, bbox in enumerate(_visible_component_bboxes(source)):
        subject = source.crop(bbox)
        subject = _keep_largest_alpha_component(subject)
        subject_bbox = subject.getchannel("A").getbbox()
        if subject_bbox is None:
            raise ValueError(f"Luoxi source component {frame_index} contains no visible pixels.")
        subject = subject.crop(subject_bbox)

        paste_x = (LUOXI_HIGH_RES_FRAME_SIZE - subject.width) // 2
        paste_y = (LUOXI_HIGH_RES_FRAME_SIZE - subject.height) // 2
        source_sheet.alpha_composite(
            subject,
            (frame_index * LUOXI_HIGH_RES_FRAME_SIZE + paste_x, paste_y),
        )

    return source_sheet


def _fit_character_frame(frame: Image.Image) -> Image.Image:
    frame = _solid_alpha(frame)
    frame = _keep_largest_alpha_component(frame)
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Luoxi source frame contains no visible pixels.")

    subject = frame.crop(bbox)
    scale = min(
        LUOXI_SUBJECT_HEIGHT / float(bbox[3] - bbox[1]),
        LUOXI_MAX_SUBJECT_WIDTH / float(bbox[2] - bbox[0]),
    )
    subject_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(subject_size, Image.Resampling.NEAREST)
    subject = _solid_alpha(subject)

    result = Image.new("RGBA", (OUTPUT_FRAME_SIZE, OUTPUT_FRAME_SIZE), (0, 0, 0, 0))
    paste_x = (OUTPUT_FRAME_SIZE - subject.width) // 2
    paste_y = LUOXI_FOOT_Y - subject.height
    result.alpha_composite(subject, (paste_x, paste_y))
    return result


def build_luoxi_sheet(source_path: Path, high_res_output_path: Path, output_path: Path) -> None:
    source = Image.open(source_path).convert("RGBA")
    centered_source = _build_centered_luoxi_source(source)
    high_res_output_path.parent.mkdir(parents=True, exist_ok=True)
    centered_source.save(high_res_output_path)
    print(
        "Luoxi high-res sheet: "
        f"{high_res_output_path} ({centered_source.width}x{centered_source.height})"
    )

    sheet = Image.new(
        "RGBA",
        (OUTPUT_FRAME_SIZE * FRAME_COUNT, OUTPUT_FRAME_SIZE),
        (0, 0, 0, 0),
    )

    for frame_index in range(FRAME_COUNT):
        left = frame_index * LUOXI_HIGH_RES_FRAME_SIZE
        right = (frame_index + 1) * LUOXI_HIGH_RES_FRAME_SIZE
        frame = centered_source.crop((left, 0, right, centered_source.height))
        sheet.alpha_composite(
            _fit_character_frame(frame),
            (frame_index * OUTPUT_FRAME_SIZE, 0),
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path)
    print(f"Luoxi sheet: {output_path} ({sheet.width}x{sheet.height})")


def build_apple_icon(source_path: Path, output_path: Path) -> None:
    source = _solid_alpha(Image.open(source_path))
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Apple source contains no visible pixels.")

    subject = source.crop(bbox)
    scale = 28.0 / float(max(subject.width, subject.height))
    subject_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(subject_size, Image.Resampling.NEAREST)
    subject = _solid_alpha(subject)

    icon = Image.new("RGBA", (APPLE_ICON_SIZE, APPLE_ICON_SIZE), (0, 0, 0, 0))
    icon.alpha_composite(
        subject,
        ((APPLE_ICON_SIZE - subject.width) // 2, (APPLE_ICON_SIZE - subject.height) // 2),
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    icon.save(output_path)
    print(f"Apple icon:  {output_path} ({icon.width}x{icon.height})")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    build_luoxi_sheet(
        root / "dev_assets/source_images/luoxi_generated_sheet_alpha.png",
        root / "resources/texture/luoxi_idle_hd.png",
        root / "resources/texture/luoxi_idle.png",
    )
    build_apple_icon(
        root / "dev_assets/source_images/apple_collectible_alpha.png",
        root / "resources/texture/apple_collectible.png",
    )


if __name__ == "__main__":
    main()
