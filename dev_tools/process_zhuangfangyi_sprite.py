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

# The source is an approximately 5x enlarged pixel image. A measured subject
# occupies about 262x339 physical pixels, or roughly 50x64 logical pixels.
# Keep that native detail in the runtime texture and scale the scene node.
OUTPUT_FRAME_WIDTH = 56
OUTPUT_FRAME_HEIGHT = 68
OUTPUT_SUBJECT_HEIGHT = 64
OUTPUT_FOOT_Y = 66


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
    red = rgb[:, :, 0].astype(np.int16)
    green = rgb[:, :, 1].astype(np.int16)
    blue = rgb[:, :, 2].astype(np.int16)
    strongest_magenta = np.maximum(red, blue)
    dark_magenta_edge = (
        (np.abs(red - blue) <= np.maximum(36, strongest_magenta // 3))
        & (green * 3 <= strongest_magenta)
        & (red + blue >= 48)
    )
    return (color_distance <= 42) | dark_magenta_edge


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


def _remove_chroma_background(frame: Image.Image) -> Image.Image:
    rgba = np.array(frame.convert("RGBA"))
    outside = _find_external_background(_is_background_candidate(rgba[:, :, :3]))
    rgba[outside] = (0, 0, 0, 0)
    return Image.fromarray(rgba)


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
    source = source.convert("RGBA")
    transparent_frames: list[Image.Image] = []

    for row in range(FRAME_ROWS):
        top = round(row * source.height / FRAME_ROWS)
        bottom = round((row + 1) * source.height / FRAME_ROWS)
        for column in range(FRAME_COLUMNS):
            left = round(column * source.width / FRAME_COLUMNS)
            right = round((column + 1) * source.width / FRAME_COLUMNS)
            frame = source.crop((left, top, right, bottom))
            transparent_frames.append(_remove_chroma_background(frame))

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
