#!/usr/bin/env python3
"""Build Zhuangfangyi high-resolution pixel sprite assets from generated sources."""

from __future__ import annotations

from pathlib import Path

from PIL import Image


FRAME_COUNT = 8
ALPHA_THRESHOLD = 0
MIN_COMPONENT_PIXELS = 100
HIGH_RES_HORIZONTAL_PADDING = 16
HIGH_RES_TOP_PADDING = 20
HIGH_RES_BOTTOM_PADDING = 20


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

            if size >= MIN_COMPONENT_PIXELS:
                components.append((size, (min_x, min_y, max_x + 1, max_y + 1)))

    largest = sorted(components, reverse=True)[:FRAME_COUNT]
    if len(largest) != FRAME_COUNT:
        raise ValueError(f"Expected {FRAME_COUNT} Zhuangfangyi source sprites, found {len(largest)}.")

    return [bbox for _size, bbox in sorted(largest, key=lambda item: item[1][0])]


def _build_hd_sheet(source_path: Path) -> tuple[Image.Image, list[tuple[int, int, int, int]]]:
    source = Image.open(source_path).convert("RGBA")
    subjects: list[Image.Image] = []
    max_subject_height = 0
    sheet_width = 0

    for bbox in _visible_component_bboxes(source):
        subject = source.crop(bbox)
        subject_bbox = subject.getchannel("A").getbbox()
        if subject_bbox is None:
            raise ValueError("Zhuangfangyi source component contains no visible pixels.")
        subject = subject.crop(subject_bbox)
        subjects.append(subject)
        max_subject_height = max(max_subject_height, subject.height)
        frame_width = subject.width + HIGH_RES_HORIZONTAL_PADDING * 2
        if frame_width % 2 != 0:
            frame_width += 1
        sheet_width += frame_width

    sheet = Image.new(
        "RGBA",
        (sheet_width, max_subject_height + HIGH_RES_TOP_PADDING + HIGH_RES_BOTTOM_PADDING),
        (0, 0, 0, 0),
    )
    regions: list[tuple[int, int, int, int]] = []
    cursor_x = 0
    for subject in subjects:
        frame_width = subject.width + HIGH_RES_HORIZONTAL_PADDING * 2
        if frame_width % 2 != 0:
            frame_width += 1
        paste_x = cursor_x + (frame_width - subject.width) // 2
        paste_y = sheet.height - HIGH_RES_BOTTOM_PADDING - subject.height
        sheet.alpha_composite(subject, (paste_x, paste_y))
        regions.append((cursor_x, 0, frame_width, sheet.height))
        cursor_x += frame_width

    return sheet, regions


def _write_animation_resource(
    output_path: Path,
    texture_path: str,
    regions: list[tuple[int, int, int, int]],
) -> None:
    lines = [
        '[gd_resource type="SpriteFrames" format=3]',
        "",
        f'[ext_resource type="Texture2D" path="{texture_path}" id="1_texture"]',
        "",
    ]
    frame_ids: list[str] = []
    for frame_index, region in enumerate(regions):
        frame_id = f"AtlasTexture_idle_{frame_index}"
        frame_ids.append(frame_id)
        lines.extend(
            [
                f'[sub_resource type="AtlasTexture" id="{frame_id}"]',
                'atlas = ExtResource("1_texture")',
                f"region = Rect2({region[0]}, {region[1]}, {region[2]}, {region[3]})",
                "",
            ]
        )

    lines.append("[resource]")
    lines.append('animations = [{')
    lines.append('"frames": [{')
    for frame_index, frame_id in enumerate(frame_ids):
        if frame_index > 0:
            lines.append("}, {")
        lines.append('"duration": 1.0,')
        lines.append(f'"texture": SubResource("{frame_id}")')
    lines.extend(
        [
            "}],",
            '"loop": true,',
            '"name": &"idle",',
            '"speed": 6.5',
            "}]",
            "",
        ]
    )
    output_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Animation: {output_path} ({len(regions)} frames)")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    sheet, regions = _build_hd_sheet(root / "dev_assets/source_images/zhuangfangyi_hd_v2_alpha.png")

    sheet_path = root / "resources/texture/zhuangfangyi_idle_hd_v2.png"
    sheet_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(sheet_path)
    print(f"Zhuangfangyi HD v2 sheet: {sheet_path} ({sheet.width}x{sheet.height})")

    _write_animation_resource(
        root / "resources/animation/zhuangfangyi_hd_v2.tres",
        "res://resources/texture/zhuangfangyi_idle_hd_v2.png",
        regions,
    )


if __name__ == "__main__":
    main()
