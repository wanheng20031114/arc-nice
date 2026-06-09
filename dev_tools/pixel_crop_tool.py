#!/usr/bin/env python3
"""
像素画裁剪与整格压缩工具。

流水线：
  1. 规范透明像素，清除透明区域残留 RGB。
  2. 删除主体周围大面积空白。
  3. 可选地扩展为正方形。
  4. 分析逻辑网格，并用最近邻中心取样压缩到原生逻辑尺寸。

用法:
  python pixel_crop_tool.py INPUT [OUTPUT]
  python pixel_crop_tool.py INPUT OUTPUT --align-grid
  python pixel_crop_tool.py INPUT OUTPUT --compress-grid
  python pixel_crop_tool.py INPUT OUTPUT --compress-grid --logical-size 37
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image, find_subject_bbox


def normalize_transparency(
    image: Image.Image,
    alpha_threshold: int = 0,
) -> Image.Image:
    """把低 alpha 像素完全清零，避免残色污染边界框和网格检测。"""
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


def crop_to_square(
    image: Image.Image,
    padding: int = 0,
    align_to_grid: bool = False,
) -> Image.Image:
    bbox = find_subject_bbox(image)
    subject_width = bbox[2] - bbox[0]
    subject_height = bbox[3] - bbox[1]
    square_side = max(subject_width, subject_height) + padding * 2

    if align_to_grid:
        analysis = analyze_image(image)
        if analysis["detection_mode"] == "exact_integer":
            grid_size = analysis["grid_cell_size"]
            square_side = (
                (square_side + grid_size - 1) // grid_size
            ) * grid_size
        # approximate 网格的物理格宽会交替变化，不能用平均值强行收窄裁区。
        # 保持完整主体方形，后续 compress_to_logical_grid 再做中心取样。

    center_x = (bbox[0] + bbox[2]) * 0.5
    center_y = (bbox[1] + bbox[3]) * 0.5
    left = round(center_x - square_side * 0.5)
    top = round(center_y - square_side * 0.5)
    right = left + square_side
    bottom = top + square_side

    source_left = max(left, 0)
    source_top = max(top, 0)
    source_right = min(right, image.width)
    source_bottom = min(bottom, image.height)
    cropped = image.crop((source_left, source_top, source_right, source_bottom))

    canvas = Image.new("RGBA", (square_side, square_side), (0, 0, 0, 0))
    paste_x = source_left - left
    paste_y = source_top - top
    canvas.paste(cropped, (paste_x, paste_y), cropped)
    return canvas


def compress_to_logical_grid(
    image: Image.Image,
    logical_size: int | None = None,
) -> tuple[Image.Image, dict]:
    analysis = analyze_image(image)

    if logical_size is None:
        if image.width == image.height:
            average_period = (
                analysis["grid_cell_width"] + analysis["grid_cell_height"]
            ) * 0.5
            detected_side = max(1, round(image.width / average_period))
            logical_width = detected_side
            logical_height = detected_side
        else:
            logical_width = analysis["recommended_canvas_grid_width"]
            logical_height = analysis["recommended_canvas_grid_height"]
    else:
        logical_width = logical_size
        logical_height = logical_size

    if logical_width <= 0 or logical_height <= 0:
        raise ValueError("逻辑尺寸必须大于 0")

    result = image.resize(
        (logical_width, logical_height),
        Image.Resampling.NEAREST,
    )
    return result, analysis


def main() -> None:
    parser = argparse.ArgumentParser(description="裁剪并整格压缩像素画")
    parser.add_argument("input_path", help="输入图片路径")
    parser.add_argument("output_path", nargs="?", default=None, help="输出图片路径")
    parser.add_argument("--padding", type=int, default=0, help="主体周围保留的物理像素")
    parser.add_argument(
        "--alpha-threshold",
        type=int,
        default=0,
        help="alpha 小于等于该值的像素会被清零，其余像素变为完全不透明",
    )
    parser.add_argument(
        "--align-grid",
        action="store_true",
        help="按检测出的近似网格调整正方形裁切边长",
    )
    parser.add_argument(
        "--compress-grid",
        action="store_true",
        help="裁切后按逻辑格压缩，不做颜色平均或平滑",
    )
    parser.add_argument(
        "--logical-size",
        type=int,
        default=None,
        help="显式指定最终正方形逻辑尺寸，例如 37",
    )
    args = parser.parse_args()

    input_path = Path(args.input_path)
    if not input_path.is_file():
        print(f"错误: 文件不存在 - {input_path}", file=sys.stderr)
        raise SystemExit(1)

    output_path = (
        Path(args.output_path)
        if args.output_path
        else input_path.with_name(f"{input_path.stem}_cropped{input_path.suffix}")
    )

    image = normalize_transparency(
        Image.open(input_path),
        alpha_threshold=max(0, min(args.alpha_threshold, 255)),
    )
    original_analysis = analyze_image(image)
    result = crop_to_square(
        image,
        padding=max(args.padding, 0),
        align_to_grid=args.align_grid,
    )

    compression_analysis = None
    if args.compress_grid or args.logical_size is not None:
        result, compression_analysis = compress_to_logical_grid(
            result,
            logical_size=args.logical_size,
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(output_path)

    bbox = original_analysis["subject_bbox"]
    print(f"输入图片:         {input_path}")
    print(f"原始尺寸:         {image.width}x{image.height} 像素")
    print(
        "主体边界框:       "
        f"({bbox['left']}, {bbox['top']}) -> ({bbox['right']}, {bbox['bottom']})"
    )
    print(
        "估算主体逻辑尺寸: "
        f"{original_analysis['subject_grid_width']}x"
        f"{original_analysis['subject_grid_height']} 格"
    )
    print(f"检测置信度:       {original_analysis['confidence']:.3f}")
    if compression_analysis is not None:
        print(
            "压缩依据格距:     "
            f"{compression_analysis['grid_cell_width']}x"
            f"{compression_analysis['grid_cell_height']} 像素"
        )
    print(f"输出尺寸:         {result.width}x{result.height} 像素")
    print(f"输出路径:         {output_path}")


if __name__ == "__main__":
    main()
