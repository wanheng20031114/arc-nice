#!/usr/bin/env python3
"""
Remove a baked grayscale checkerboard from generated pixel art.

The foreground is seeded from colored pixels, filtered by connected-component
size, and written with a hard alpha channel so later nearest-neighbor tools do
not blend background colors into the sprite.

Usage:
  python checkerboard_background_remover.py INPUT OUTPUT
  python checkerboard_background_remover.py INPUT OUTPUT --fill-holes
  python checkerboard_background_remover.py INPUT OUTPUT --min-component-pixels 1000
"""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path
import sys

import numpy as np
from PIL import Image


def _connected_components(mask: np.ndarray) -> list[list[tuple[int, int]]]:
    height, width = mask.shape
    visited = np.zeros_like(mask, dtype=bool)
    components: list[list[tuple[int, int]]] = []

    for start_y, start_x in zip(*np.nonzero(mask)):
        if visited[start_y, start_x]:
            continue

        stack = [(int(start_y), int(start_x))]
        visited[start_y, start_x] = True
        component: list[tuple[int, int]] = []

        while stack:
            y, x = stack.pop()
            component.append((y, x))
            for offset_y, offset_x in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                next_y = y + offset_y
                next_x = x + offset_x
                if not (0 <= next_y < height and 0 <= next_x < width):
                    continue
                if visited[next_y, next_x] or not mask[next_y, next_x]:
                    continue
                visited[next_y, next_x] = True
                stack.append((next_y, next_x))

        components.append(component)

    return components


def _fill_enclosed_holes(mask: np.ndarray) -> np.ndarray:
    height, width = mask.shape
    outside = np.zeros_like(mask, dtype=bool)
    queue: deque[tuple[int, int]] = deque()

    for x in range(width):
        for y in (0, height - 1):
            if not mask[y, x] and not outside[y, x]:
                outside[y, x] = True
                queue.append((y, x))
    for y in range(height):
        for x in (0, width - 1):
            if not mask[y, x] and not outside[y, x]:
                outside[y, x] = True
                queue.append((y, x))

    while queue:
        y, x = queue.popleft()
        for offset_y, offset_x in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            next_y = y + offset_y
            next_x = x + offset_x
            if not (0 <= next_y < height and 0 <= next_x < width):
                continue
            if mask[next_y, next_x] or outside[next_y, next_x]:
                continue
            outside[next_y, next_x] = True
            queue.append((next_y, next_x))

    return ~outside


def remove_checkerboard(
    image: Image.Image,
    chroma_threshold: int,
    min_component_pixels: int,
    fill_holes: bool,
) -> Image.Image:
    rgba = np.array(image.convert("RGBA"))
    rgb = rgba[:, :, :3].astype(np.int16)
    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    seed_mask = chroma >= chroma_threshold

    foreground = np.zeros_like(seed_mask, dtype=bool)
    for component in _connected_components(seed_mask):
        if len(component) < min_component_pixels:
            continue
        for y, x in component:
            foreground[y, x] = True

    if fill_holes:
        foreground = _fill_enclosed_holes(foreground)

    rgba[:, :, 3] = np.where(foreground, 255, 0).astype(np.uint8)
    rgba[~foreground, :3] = 0
    return Image.fromarray(rgba)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Remove a baked grayscale checkerboard from pixel art",
    )
    parser.add_argument("input_path", help="Input image path")
    parser.add_argument("output_path", help="Output PNG path")
    parser.add_argument(
        "--chroma-threshold",
        type=int,
        default=6,
        help="Minimum RGB channel spread treated as foreground (default: 6)",
    )
    parser.add_argument(
        "--min-component-pixels",
        type=int,
        default=150,
        help="Discard colored components smaller than this physical area",
    )
    parser.add_argument(
        "--fill-holes",
        action="store_true",
        help="Keep neutral-colored pixels enclosed by the colored outline",
    )
    args = parser.parse_args()

    input_path = Path(args.input_path)
    if not input_path.is_file():
        print(f"Error: file does not exist - {input_path}", file=sys.stderr)
        raise SystemExit(1)

    output_path = Path(args.output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result = remove_checkerboard(
        Image.open(input_path),
        chroma_threshold=max(1, args.chroma_threshold),
        min_component_pixels=max(1, args.min_component_pixels),
        fill_holes=args.fill_holes,
    )
    result.save(output_path)

    bbox = result.getchannel("A").getbbox()
    print(f"Input:            {input_path}")
    print(f"Output:           {output_path}")
    print(f"Foreground bbox:  {bbox}")
    print(f"Output size:      {result.width}x{result.height}")


if __name__ == "__main__":
    main()
