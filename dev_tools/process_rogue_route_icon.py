#!/usr/bin/env python3
"""把原生透明生成图收口为低像素、有限色板的路线图图标。"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image


def _nearest_color(color: tuple[int, int, int], palette: list[tuple[int, int, int]]):
    return min(
        palette,
        key=lambda candidate: sum(
            (int(color[channel]) - int(candidate[channel])) ** 2
            for channel in range(3)
        ),
    )


def process_icon(
    source_path: Path,
    output_path: Path,
    canvas_size: int,
    subject_size: int,
    color_count: int,
    alpha_threshold: int,
    sampling: str,
    reduced_alpha_threshold: int,
    reserved_colors: list[tuple[int, int, int]],
) -> None:
    source = Image.open(source_path).convert("RGBA")
    normalized = Image.new("RGBA", source.size, (0, 0, 0, 0))
    normalized_pixels = []
    for red, green, blue, alpha in source.getdata():
        if alpha <= alpha_threshold:
            normalized_pixels.append((0, 0, 0, 0))
        else:
            normalized_pixels.append((red, green, blue, 255))
    normalized.putdata(normalized_pixels)

    bbox = normalized.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError(f"图标没有可见主体：{source_path}")
    subject_width = bbox[2] - bbox[0]
    subject_height = bbox[3] - bbox[1]
    square_side = max(
        max(subject_width, subject_height),
        int(math.ceil(max(subject_width, subject_height) * canvas_size / subject_size)),
    )
    center_x = (bbox[0] + bbox[2]) * 0.5
    center_y = (bbox[1] + bbox[3]) * 0.5
    left = int(round(center_x - square_side * 0.5))
    top = int(round(center_y - square_side * 0.5))

    square = Image.new("RGBA", (square_side, square_side), (0, 0, 0, 0))
    source_left = max(left, 0)
    source_top = max(top, 0)
    source_right = min(left + square_side, normalized.width)
    source_bottom = min(top + square_side, normalized.height)
    crop = normalized.crop((source_left, source_top, source_right, source_bottom))
    square.alpha_composite(crop, (source_left - left, source_top - top))
    resampling = (
        Image.Resampling.NEAREST
        if sampling == "nearest"
        else Image.Resampling.BOX
    )
    reduced = square.resize((canvas_size, canvas_size), resampling)

    visible_colors = [
        pixel[:3]
        for pixel in reduced.getdata()
        if pixel[3] >= reduced_alpha_threshold
    ]
    if not visible_colors:
        raise ValueError(f"缩小后图标没有可见像素：{source_path}")
    strip = Image.new("RGB", (len(visible_colors), 1))
    strip.putdata(visible_colors)
    quantized_strip = strip.quantize(
        colors=max(2, color_count - len(reserved_colors)),
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")
    palette = sorted(set(quantized_strip.getdata()).union(reserved_colors))

    final = Image.new("RGBA", reduced.size, (0, 0, 0, 0))
    final_pixels = []
    color_cache: dict[tuple[int, int, int], tuple[int, int, int]] = {}
    for red, green, blue, alpha in reduced.getdata():
        if alpha < reduced_alpha_threshold:
            final_pixels.append((0, 0, 0, 0))
            continue
        source_color = (red, green, blue)
        mapped = color_cache.get(source_color)
        if mapped is None:
            mapped = _nearest_color(source_color, palette)
            color_cache[source_color] = mapped
        final_pixels.append((*mapped, 255))
    final.putdata(final_pixels)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    final.save(output_path)
    visible_count = sum(pixel[3] > 0 for pixel in final.getdata())
    print(
        f"{source_path.name} -> {output_path} | "
        f"{canvas_size}x{canvas_size}, 主体目标 {subject_size}, "
        f"可见像素 {visible_count}, 色数 {len(palette)}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_path", type=Path)
    parser.add_argument("output_path", type=Path)
    parser.add_argument("--canvas-size", type=int, default=16)
    parser.add_argument("--subject-size", type=int, default=12)
    parser.add_argument("--colors", type=int, default=6)
    parser.add_argument("--alpha-threshold", type=int, default=24)
    parser.add_argument(
        "--sampling",
        choices=("box", "nearest"),
        default="box",
        help="生成图通常存在近似网格，box 可避免一像素符号被最近邻漏采样。",
    )
    parser.add_argument("--reduced-alpha-threshold", type=int, default=96)
    parser.add_argument(
        "--reserve-color",
        action="append",
        default=[],
        help="强制色板保留的 #RRGGBB 强调色，可重复提供。",
    )
    args = parser.parse_args()
    if not args.input_path.is_file():
        parser.error(f"输入不存在：{args.input_path}")
    if not (1 <= args.subject_size <= args.canvas_size):
        parser.error("subject-size 必须位于 1 到 canvas-size")
    reserved_colors = []
    for value in args.reserve_color:
        normalized = value.removeprefix("#")
        if len(normalized) != 6:
            parser.error(f"reserve-color 必须是 #RRGGBB：{value}")
        try:
            reserved_colors.append(
                tuple(int(normalized[index:index + 2], 16) for index in (0, 2, 4))
            )
        except ValueError:
            parser.error(f"reserve-color 必须是十六进制颜色：{value}")
    process_icon(
        args.input_path,
        args.output_path,
        args.canvas_size,
        args.subject_size,
        args.colors,
        args.alpha_threshold,
        args.sampling,
        max(0, min(args.reduced_alpha_threshold, 255)),
        reserved_colors,
    )


if __name__ == "__main__":
    main()
