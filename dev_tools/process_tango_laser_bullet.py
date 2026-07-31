#!/usr/bin/env python3
"""Convert the approved ImageGen Tango laser board to a native pixel sheet.

The source remains in ``dev_assets/source_images/tango`` as visual provenance.
This script only crops its four authored poses, reduces the detected logical
grid with nearest-neighbour sampling, and snaps edge colours to Tango's palette.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
IMAGEGEN_SOURCE_PATH = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "tango"
    / "tango_laser_bullet_board_v1_imagegen.png"
)
SOURCE_PATH = (
    ROOT
    / "dev_assets"
    / "source_images"
    / "tango"
    / "tango_laser_bullet_board_v1_alpha.png"
)
OUTPUT_PATH = (
    ROOT
    / "resources"
    / "texture"
    / "player"
    / "tango"
    / "tango_laser_bullet.png"
)
PREVIEW_PATH = (
    ROOT
    / "dev_assets"
    / "generated_previews"
    / "tango_laser_bullet_v1_preview.png"
)
EXPECTED_SOURCE_SHA256 = (
    "540970be1dbaa4da21eec3e1f9c7755371817d698b0d75842a6d286e375177e4"
)
EXPECTED_IMAGEGEN_SOURCE_SHA256 = (
    "51bedb303cdf90ca78ea4b2fed4235b9e79abf0fa699be8abe9f12b1c98053da"
)

FRAME_SIZE = (24, 8)
SOURCE_COMPONENT_BOXES = (
    (157, 309, 413, 399),
    (623, 309, 938, 399),
    (1144, 309, 1467, 399),
    (1641, 309, 1994, 399),
)
LOGICAL_COMPONENT_WIDTHS = (14, 18, 18, 20)
LOGICAL_COMPONENT_HEIGHT = 5
NOSE_X = 21

PALETTE = (
    (18, 27, 35, 255),
    (43, 110, 116, 255),
    (56, 236, 243, 255),
    (228, 252, 252, 255),
)


def _verify_source() -> None:
    if not IMAGEGEN_SOURCE_PATH.exists():
        raise FileNotFoundError(IMAGEGEN_SOURCE_PATH)
    imagegen_source_hash = hashlib.sha256(
        IMAGEGEN_SOURCE_PATH.read_bytes()
    ).hexdigest()
    if imagegen_source_hash != EXPECTED_IMAGEGEN_SOURCE_SHA256:
        raise RuntimeError(
            "Tango laser original ImageGen board changed; preserve the approved "
            f"visual provenance (got {imagegen_source_hash})."
        )
    if not SOURCE_PATH.exists():
        raise FileNotFoundError(SOURCE_PATH)
    source_hash = hashlib.sha256(SOURCE_PATH.read_bytes()).hexdigest()
    if source_hash != EXPECTED_SOURCE_SHA256:
        raise RuntimeError(
            "Tango laser ImageGen source changed; inspect it and update the "
            f"crop contract first (got {source_hash})."
        )


def _nearest_palette_colour(pixel: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    if pixel[3] < 96:
        return (0, 0, 0, 0)
    return min(
        PALETTE,
        key=lambda colour: sum(
            (int(pixel[channel]) - colour[channel]) ** 2 for channel in range(3)
        ),
    )


def _snap_frame(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    snapped = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
    snapped.putdata([_nearest_palette_colour(pixel) for pixel in rgba.getdata()])
    return snapped


def _build_sheet() -> tuple[Image.Image, list[tuple[int, int, int, int]]]:
    source = Image.open(SOURCE_PATH).convert("RGBA")
    sheet = Image.new(
        "RGBA",
        (FRAME_SIZE[0] * len(SOURCE_COMPONENT_BOXES), FRAME_SIZE[1]),
        (0, 0, 0, 0),
    )
    frame_boxes: list[tuple[int, int, int, int]] = []
    for frame_index, (source_box, logical_width) in enumerate(
        zip(SOURCE_COMPONENT_BOXES, LOGICAL_COMPONENT_WIDTHS, strict=True)
    ):
        frame = source.crop(source_box).resize(
            (logical_width, LOGICAL_COMPONENT_HEIGHT),
            Image.Resampling.NEAREST,
        )
        frame = _snap_frame(frame)
        if frame.getchannel("A").getbbox() is None:
            raise RuntimeError(f"Tango laser frame {frame_index} became empty.")
        paste_x = frame_index * FRAME_SIZE[0] + NOSE_X - logical_width + 1
        paste_y = (FRAME_SIZE[1] - LOGICAL_COMPONENT_HEIGHT) // 2
        sheet.alpha_composite(frame, (paste_x, paste_y))
        local_box = frame.getchannel("A").getbbox()
        if local_box is None:
            raise RuntimeError(f"Tango laser frame {frame_index} has no alpha bbox.")
        frame_boxes.append(local_box)
    return sheet, frame_boxes


def _save_preview(sheet: Image.Image) -> None:
    scale = 10
    gap = 3
    frame_width, frame_height = FRAME_SIZE
    preview = Image.new(
        "RGBA",
        (
            (frame_width * len(SOURCE_COMPONENT_BOXES) + gap * 3) * scale,
            frame_height * scale,
        ),
        (17, 25, 40, 255),
    )
    for frame_index in range(len(SOURCE_COMPONENT_BOXES)):
        frame = sheet.crop(
            (
                frame_index * frame_width,
                0,
                (frame_index + 1) * frame_width,
                frame_height,
            )
        ).resize((frame_width * scale, frame_height * scale), Image.Resampling.NEAREST)
        preview.alpha_composite(frame, (frame_index * (frame_width + gap) * scale, 0))
    PREVIEW_PATH.parent.mkdir(parents=True, exist_ok=True)
    preview.save(PREVIEW_PATH, optimize=True)


def main() -> None:
    _verify_source()
    sheet, frame_boxes = _build_sheet()
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUTPUT_PATH, optimize=True)
    _save_preview(sheet)
    print(f"source:  {SOURCE_PATH}")
    print(f"runtime: {sheet.size[0]}x{sheet.size[1]} -> {OUTPUT_PATH}")
    print(f"preview: {PREVIEW_PATH}")
    print(f"frame bboxes: {frame_boxes}")


if __name__ == "__main__":
    main()
