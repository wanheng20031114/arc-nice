#!/usr/bin/env python3
"""Build Linglan NPC sprite sheet and SpriteFrames from generated transparent sources."""

from __future__ import annotations

from collections import OrderedDict
from pathlib import Path

from PIL import Image


LOW_RES_FRAME_HEIGHT = 34
LOW_RES_HORIZONTAL_PADDING = 2
LINGLAN_SUBJECT_HEIGHT = 30
LINGLAN_FOOT_Y = 32
MIN_FRAME_WIDTH = 32
ALPHA_THRESHOLD = 0


FrameRegion = tuple[int, int, int, int]


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


def _grid_cell(image: Image.Image, columns: int, rows: int, column: int, row: int) -> Image.Image:
    cell_width = image.width / float(columns)
    cell_height = image.height / float(rows)
    left = round(column * cell_width)
    top = round(row * cell_height)
    right = round((column + 1) * cell_width)
    bottom = round((row + 1) * cell_height)
    return image.crop((left, top, right, bottom))


def _fit_frame(source_frame: Image.Image) -> Image.Image:
    source_frame = _solid_alpha(source_frame)
    bbox = source_frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Linglan source frame contains no visible pixels.")

    subject = source_frame.crop(bbox)
    scale = LINGLAN_SUBJECT_HEIGHT / float(subject.height)
    subject_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(subject_size, Image.Resampling.BOX)
    subject = _solid_alpha(subject)
    resized_bbox = subject.getchannel("A").getbbox()
    if resized_bbox is None:
        raise ValueError("Linglan resized frame contains no visible pixels.")
    subject = subject.crop(resized_bbox)

    frame_width = max(MIN_FRAME_WIDTH, subject.width + LOW_RES_HORIZONTAL_PADDING * 2)
    if frame_width % 2 != 0:
        frame_width += 1

    result = Image.new("RGBA", (frame_width, LOW_RES_FRAME_HEIGHT), (0, 0, 0, 0))
    paste_x = (frame_width - subject.width) // 2
    paste_y = LINGLAN_FOOT_Y - subject.height
    result.alpha_composite(subject, (paste_x, paste_y))
    return result


def _append_frame(
    frames: list[tuple[str, Image.Image]],
    frame_name: str,
    source_frame: Image.Image,
) -> None:
    frames.append((frame_name, _fit_frame(source_frame)))


def _collect_frames(walk_die_path: Path, idle_path: Path) -> tuple[list[tuple[str, Image.Image]], OrderedDict[str, list[str]]]:
    walk_die = Image.open(walk_die_path).convert("RGBA")
    idle = Image.open(idle_path).convert("RGBA")
    frames: list[tuple[str, Image.Image]] = []
    animations: OrderedDict[str, list[str]] = OrderedDict()

    idle_cells = {
        "idle_up": (0, 0),
        "idle_down": (1, 0),
        "idle_left": (2, 0),
        "idle_right": (3, 0),
    }
    for animation_name, (column, row) in idle_cells.items():
        frame_name = f"{animation_name}_0"
        _append_frame(frames, frame_name, _grid_cell(idle, 4, 1, column, row))
        animations[animation_name] = [frame_name]
    animations["idle"] = ["idle_down_0"]

    # The reference sheet is visually ordered down, left, right, up, then die.
    movement_rows = OrderedDict(
        [
            ("move_down", 0),
            ("move_left", 1),
            ("move_right", 2),
            ("move_up", 3),
            ("die", 4),
        ]
    )
    for animation_name, row in movement_rows.items():
        animation_frames: list[str] = []
        for column in range(4):
            frame_name = f"{animation_name}_{column}"
            _append_frame(frames, frame_name, _grid_cell(walk_die, 4, 5, column, row))
            animation_frames.append(frame_name)
        animations[animation_name] = animation_frames

    return frames, animations


def _build_sheet(frames: list[tuple[str, Image.Image]]) -> tuple[Image.Image, dict[str, FrameRegion]]:
    sheet_width = sum(frame.width for _name, frame in frames)
    sheet = Image.new("RGBA", (sheet_width, LOW_RES_FRAME_HEIGHT), (0, 0, 0, 0))
    regions: dict[str, FrameRegion] = {}
    cursor_x = 0
    for frame_name, frame in frames:
        sheet.alpha_composite(frame, (cursor_x, 0))
        regions[frame_name] = (cursor_x, 0, frame.width, frame.height)
        cursor_x += frame.width
    return sheet, regions


def _animation_speed(animation_name: str) -> float:
    if animation_name.startswith("idle"):
        return 1.0
    if animation_name == "die":
        return 8.0
    return 8.0


def _animation_loop(animation_name: str) -> bool:
    return animation_name != "die"


def _write_animation_resource(
    output_path: Path,
    texture_path: str,
    regions: dict[str, FrameRegion],
    animations: OrderedDict[str, list[str]],
) -> None:
    lines = [
        '[gd_resource type="SpriteFrames" format=3]',
        "",
        f'[ext_resource type="Texture2D" path="{texture_path}" id="1_texture"]',
        "",
    ]
    for frame_name, region in regions.items():
        lines.extend(
            [
                f'[sub_resource type="AtlasTexture" id="AtlasTexture_{frame_name}"]',
                'atlas = ExtResource("1_texture")',
                f"region = Rect2({region[0]}, {region[1]}, {region[2]}, {region[3]})",
                "",
            ]
        )

    animation_entries: list[str] = []
    for animation_name, frame_names in animations.items():
        frame_entries = []
        for frame_name in frame_names:
            frame_entries.append(
                '{\n"duration": 1.0,\n'
                f'"texture": SubResource("AtlasTexture_{frame_name}")\n}}'
            )
        animation_entries.append(
            '{\n'
            f'"frames": [{", ".join(frame_entries)}],\n'
            f'"loop": {str(_animation_loop(animation_name)).lower()},\n'
            f'"name": &"{animation_name}",\n'
            f'"speed": {_animation_speed(animation_name):.1f}\n'
            '}'
        )

    lines.append("[resource]")
    lines.append(f"animations = [{', '.join(animation_entries)}]")
    lines.append("")
    output_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Linglan animation: {output_path} ({len(animations)} animations)")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    frames, animations = _collect_frames(
        root / "dev_assets/source_images/linglan_walk_die_alpha.png",
        root / "dev_assets/source_images/linglan_idle_alpha.png",
    )
    sheet, regions = _build_sheet(frames)

    sheet_path = root / "resources/texture/linglan.png"
    sheet_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(sheet_path)
    print(f"Linglan sheet: {sheet_path} ({sheet.width}x{sheet.height})")

    _write_animation_resource(
        root / "resources/animation/linglan.tres",
        "res://resources/texture/linglan.png",
        regions,
        animations,
    )


if __name__ == "__main__":
    main()
