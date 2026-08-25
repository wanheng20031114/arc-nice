#!/usr/bin/env python3
"""Build the runtime 8-frame Zhuang Fangyi idle sheet from the source image."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


FRAME_COLUMNS = 4
FRAME_ROWS = 2

# The source is an approximately 5x enlarged pixel image. A measured subject
# occupies about 262x339 physical pixels, or roughly 50x64 logical pixels.
# Keep that native detail in the runtime texture and scale the scene node.
OUTPUT_FRAME_WIDTH = 56
OUTPUT_FRAME_HEIGHT = 68
OUTPUT_SUBJECT_HEIGHT = 64
OUTPUT_FOOT_Y = 66


def _require_native_transparency(image: Image.Image) -> Image.Image:
    if "A" not in image.getbands():
        raise ValueError(
            "Zhuang Fangyi source has no Alpha channel. Provide an ImageGen "
            "sheet exported with a native transparent background."
        )
    minimum_alpha, maximum_alpha = image.getchannel("A").getextrema()
    if minimum_alpha >= 255 or maximum_alpha == 0:
        raise ValueError(
            "Zhuang Fangyi source must contain both transparent and visible "
            "pixels in its native Alpha channel."
        )
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
    return rgba


def _fit_frame(frame: Image.Image, scale: float) -> Image.Image:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("A source frame contains no visible pixels.")

    subject = frame.crop(bbox)
    target_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(target_size, Image.Resampling.NEAREST)

    result = Image.new(
        "RGBA",
        (OUTPUT_FRAME_WIDTH, OUTPUT_FRAME_HEIGHT),
        (0, 0, 0, 0),
    )
    paste_x = (OUTPUT_FRAME_WIDTH - subject.width) // 2
    paste_y = OUTPUT_FOOT_Y - subject.height
    result.alpha_composite(subject, (paste_x, paste_y))
    return result


def build_sheet(source: Image.Image) -> Image.Image:
    source = _require_native_transparency(source)
    transparent_frames: list[Image.Image] = []

    for row in range(FRAME_ROWS):
        top = round(row * source.height / FRAME_ROWS)
        bottom = round((row + 1) * source.height / FRAME_ROWS)
        for column in range(FRAME_COLUMNS):
            left = round(column * source.width / FRAME_COLUMNS)
            right = round((column + 1) * source.width / FRAME_COLUMNS)
            frame = source.crop((left, top, right, bottom))
            transparent_frames.append(frame)

    subject_heights = []
    for frame in transparent_frames:
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise ValueError("A source frame contains no visible pixels.")
        subject_heights.append(bbox[3] - bbox[1])

    shared_scale = OUTPUT_SUBJECT_HEIGHT / max(subject_heights)
    sheet = Image.new(
        "RGBA",
        (
            OUTPUT_FRAME_WIDTH * FRAME_COLUMNS * FRAME_ROWS,
            OUTPUT_FRAME_HEIGHT,
        ),
        (0, 0, 0, 0),
    )

    for frame_index, frame in enumerate(transparent_frames):
        processed = _fit_frame(frame, shared_scale)
        sheet.alpha_composite(
            processed,
            (frame_index * OUTPUT_FRAME_WIDTH, 0),
        )

    return sheet


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_path")
    parser.add_argument("output_path")
    args = parser.parse_args()

    input_path = Path(args.input_path)
    output_path = Path(args.output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    sheet = build_sheet(Image.open(input_path))
    sheet.save(output_path)

    print(f"Input:  {input_path}")
    print(f"Output: {output_path}")
    print(f"Size:   {sheet.width}x{sheet.height}")
    for frame_index in range(FRAME_COLUMNS * FRAME_ROWS):
        left = frame_index * OUTPUT_FRAME_WIDTH
        frame = sheet.crop(
            (left, 0, left + OUTPUT_FRAME_WIDTH, OUTPUT_FRAME_HEIGHT)
        )
        print(f"Frame {frame_index}: {frame.getchannel('A').getbbox()}")


if __name__ == "__main__":
    main()
