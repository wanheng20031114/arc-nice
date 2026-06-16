#!/usr/bin/env python3
"""Build a 32px-frame Zhuang Fangyi idle sheet matching the player sprite scale."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


FRAME_COUNT = 8
SOURCE_FRAME_WIDTH = 56
SOURCE_FRAME_HEIGHT = 68
OUTPUT_FRAME_SIZE = 32
OUTPUT_SUBJECT_HEIGHT = 30
OUTPUT_FOOT_Y = 31
ALPHA_THRESHOLD = 96


def _fit_frame(frame: Image.Image) -> Image.Image:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("A source frame contains no visible pixels.")

    subject = frame.crop(bbox)
    scale = OUTPUT_SUBJECT_HEIGHT / (bbox[3] - bbox[1])
    target_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(target_size, Image.Resampling.BOX)

    pixels = subject.load()
    for y in range(subject.height):
        for x in range(subject.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha < ALPHA_THRESHOLD:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)

    result = Image.new(
        "RGBA",
        (OUTPUT_FRAME_SIZE, OUTPUT_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    result.alpha_composite(
        subject,
        ((OUTPUT_FRAME_SIZE - subject.width) // 2, OUTPUT_FOOT_Y - subject.height),
    )
    return result


def build_sheet(source: Image.Image) -> Image.Image:
    source = source.convert("RGBA")
    sheet = Image.new(
        "RGBA",
        (OUTPUT_FRAME_SIZE * FRAME_COUNT, OUTPUT_FRAME_SIZE),
        (0, 0, 0, 0),
    )

    for frame_index in range(FRAME_COUNT):
        frame = source.crop(
            (
                frame_index * SOURCE_FRAME_WIDTH,
                0,
                (frame_index + 1) * SOURCE_FRAME_WIDTH,
                SOURCE_FRAME_HEIGHT,
            )
        )
        sheet.alpha_composite(_fit_frame(frame), (frame_index * OUTPUT_FRAME_SIZE, 0))

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
    for frame_index in range(FRAME_COUNT):
        left = frame_index * OUTPUT_FRAME_SIZE
        frame = sheet.crop((left, 0, left + OUTPUT_FRAME_SIZE, OUTPUT_FRAME_SIZE))
        print(f"Frame {frame_index}: {frame.getchannel('A').getbbox()}")


if __name__ == "__main__":
    main()
