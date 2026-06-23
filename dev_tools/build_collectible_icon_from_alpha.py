#!/usr/bin/env python3
"""
Build a 32x32 collectible icon from a generated alpha PNG.

The generated source is expected to already have a transparent background. The
script estimates the source's visual pixel block size, crops the subject, then
resizes the subject to its own logical pixel dimensions and centers it on a
32x32 transparent canvas. This avoids stretching every item to the same height.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image


def _alpha_normalized(image: Image.Image, alpha_threshold: int) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha <= alpha_threshold:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return rgba


def build_icon(
    input_path: Path,
    output_path: Path,
    alpha_threshold: int,
    min_subject_size: int,
    max_subject_size: int,
) -> dict:
    source = _alpha_normalized(Image.open(input_path), alpha_threshold)
    analysis = analyze_image(source)
    bbox_data = analysis["subject_bbox"]
    bbox = (
        int(bbox_data["left"]),
        int(bbox_data["top"]),
        int(bbox_data["right"]),
        int(bbox_data["bottom"]),
    )
    if bbox[2] <= bbox[0] or bbox[3] <= bbox[1]:
        raise ValueError(f"No visible subject found in {input_path}")

    subject = source.crop(bbox)
    logical_width = max(1, int(analysis["subject_grid_width"]))
    logical_height = max(1, int(analysis["subject_grid_height"]))
    largest_dimension = max(logical_width, logical_height)
    if largest_dimension < min_subject_size:
        scale = float(min_subject_size) / float(largest_dimension)
        logical_width = max(1, round(logical_width * scale))
        logical_height = max(1, round(logical_height * scale))
    if max(logical_width, logical_height) > max_subject_size:
        scale = float(max_subject_size) / float(max(logical_width, logical_height))
        logical_width = max(1, round(logical_width * scale))
        logical_height = max(1, round(logical_height * scale))

    resized = subject.resize((logical_width, logical_height), Image.Resampling.NEAREST)
    output = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    paste_x = round((32 - logical_width) / 2.0)
    paste_y = round((32 - logical_height) / 2.0)
    output.alpha_composite(resized, (paste_x, paste_y))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output.save(output_path)

    output_bbox = output.getchannel("A").getbbox()
    return {
        "input": str(input_path),
        "output": str(output_path),
        "source_size": [source.width, source.height],
        "source_bbox": bbox,
        "grid_cell_width": analysis["grid_cell_width"],
        "grid_cell_height": analysis["grid_cell_height"],
        "confidence": analysis["confidence"],
        "subject_grid_size": [analysis["subject_grid_width"], analysis["subject_grid_height"]],
        "final_subject_size": [logical_width, logical_height],
        "final_bbox": output_bbox,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a centered 32x32 collectible icon from alpha PNG.")
    parser.add_argument("input_path", type=Path)
    parser.add_argument("output_path", type=Path)
    parser.add_argument("--alpha-threshold", type=int, default=24)
    parser.add_argument("--min-subject-size", type=int, default=12)
    parser.add_argument("--max-subject-size", type=int, default=26)
    args = parser.parse_args()

    try:
        result = build_icon(
            args.input_path,
            args.output_path,
            max(0, min(args.alpha_threshold, 255)),
            max(1, args.min_subject_size),
            max(1, args.max_subject_size),
        )
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
