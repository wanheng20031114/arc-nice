#!/usr/bin/env python3
"""Build the runtime 8-frame Zhuang Fangyi idle sheet from the source image."""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image


FRAME_COLUMNS = 4
FRAME_ROWS = 2
OUTPUT_FRAME_SIZE = 32


def _is_background_candidate(rgb: np.ndarray) -> np.ndarray:
    border = np.concatenate(
        (
            rgb[0, :, :],
            rgb[-1, :, :],
            rgb[:, 0, :],
            rgb[:, -1, :],
        ),
        axis=0,
    ).astype(np.int16)
    key_color = np.median(border, axis=0)
    color_distance = np.max(
        np.abs(rgb.astype(np.int16) - key_color),
        axis=2,
    )
    return color_distance <= 42


def _find_external_background(candidate: np.ndarray) -> np.ndarray:
    height, width = candidate.shape
    outside = np.zeros_like(candidate, dtype=bool)
    queue: deque[tuple[int, int]] = deque()

    for x in range(width):
        for y in (0, height - 1):
            if candidate[y, x] and not outside[y, x]:
                outside[y, x] = True
                queue.append((y, x))
    for y in range(height):
        for x in (0, width - 1):
            if candidate[y, x] and not outside[y, x]:
                outside[y, x] = True
                queue.append((y, x))

    while queue:
        y, x = queue.popleft()
        for offset_y in (-1, 0, 1):
            for offset_x in (-1, 0, 1):
                if offset_x == 0 and offset_y == 0:
                    continue
                next_y = y + offset_y
                next_x = x + offset_x
                if not (0 <= next_y < height and 0 <= next_x < width):
                    continue
                if outside[next_y, next_x] or not candidate[next_y, next_x]:
                    continue
                outside[next_y, next_x] = True
                queue.append((next_y, next_x))

    return outside


def _remove_checkerboard(frame: Image.Image) -> Image.Image:
    rgba = np.array(frame.convert("RGBA"))
    outside = _find_external_background(_is_background_candidate(rgba[:, :, :3]))
    rgba[outside] = (0, 0, 0, 0)
    return Image.fromarray(rgba)


def _fit_frame(frame: Image.Image) -> Image.Image:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("A source frame contains no visible pixels.")

    subject = frame.crop(bbox)
    scale = min(
        OUTPUT_FRAME_SIZE / subject.width,
        OUTPUT_FRAME_SIZE / subject.height,
    )
    target_size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    subject = subject.resize(target_size, Image.Resampling.NEAREST)

    result = Image.new(
        "RGBA",
        (OUTPUT_FRAME_SIZE, OUTPUT_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    paste_x = (OUTPUT_FRAME_SIZE - subject.width) // 2
    paste_y = OUTPUT_FRAME_SIZE - subject.height
    result.alpha_composite(subject, (paste_x, paste_y))
    return result


def build_sheet(source: Image.Image) -> Image.Image:
    source = source.convert("RGBA")
    sheet = Image.new(
        "RGBA",
        (OUTPUT_FRAME_SIZE * FRAME_COLUMNS * FRAME_ROWS, OUTPUT_FRAME_SIZE),
        (0, 0, 0, 0),
    )

    frame_index = 0
    for row in range(FRAME_ROWS):
        top = round(row * source.height / FRAME_ROWS)
        bottom = round((row + 1) * source.height / FRAME_ROWS)
        for column in range(FRAME_COLUMNS):
            left = round(column * source.width / FRAME_COLUMNS)
            right = round((column + 1) * source.width / FRAME_COLUMNS)
            frame = source.crop((left, top, right, bottom))
            processed = _fit_frame(_remove_checkerboard(frame))
            sheet.alpha_composite(
                processed,
                (frame_index * OUTPUT_FRAME_SIZE, 0),
            )
            frame_index += 1

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
        left = frame_index * OUTPUT_FRAME_SIZE
        frame = sheet.crop((left, 0, left + OUTPUT_FRAME_SIZE, OUTPUT_FRAME_SIZE))
        print(f"Frame {frame_index}: {frame.getchannel('A').getbbox()}")


if __name__ == "__main__":
    main()
