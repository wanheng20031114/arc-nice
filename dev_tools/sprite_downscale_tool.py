#!/usr/bin/env python3
"""
像素画无损压缩工具

针对"逻辑像素被放大 N 倍"的像素画 / 精灵图：
  1. 自动检测每个逻辑像素由多少个实际像素组成（网格单元大小 N）
  2. 用最近邻（Nearest Neighbor）缩放将图片缩小 N 倍
  3. 输出的图片中，每 1 个实际像素 = 原图中 1 个逻辑像素

不会去除空白区域，不会改变子图的相对位置，只做像素级无损压缩。

用法:
  python sprite_downscale_tool.py <input_path> [output_path]
  python sprite_downscale_tool.py <input_path> --scale N           # 手动指定缩放因子
  python sprite_downscale_tool.py <input_path> --detect-only       # 仅检测，不输出图片
"""

import sys
import argparse
from pathlib import Path
from PIL import Image

from pixel_grid_analyzer import detect_grid_size


def downscale_pixel_art(image: Image.Image, scale_factor: int) -> Image.Image:
    """
    将像素画按 scale_factor 倍进行最近邻缩小。

    如果原图每个逻辑像素由 NxN 个实际像素组成，传入 scale_factor=N，
    输出图片中每个实际像素恰好对应一个逻辑像素。
    """
    if scale_factor <= 1:
        return image.copy()

    new_width = image.size[0] // scale_factor
    new_height = image.size[1] // scale_factor

    if new_width <= 0 or new_height <= 0:
        print(f"警告: 缩小后尺寸为 {new_width}x{new_height}，跳过缩放", file=sys.stderr)
        return image.copy()

    return image.resize((new_width, new_height), Image.NEAREST)


def main():
    parser = argparse.ArgumentParser(
        description="像素画无损压缩工具 - 将放大的逻辑像素压缩回 1:1",
    )
    parser.add_argument("input_path", help="输入图片路径")
    parser.add_argument("output_path", nargs="?", default=None,
                        help="输出图片路径（默认在文件名后加 _1x）")
    parser.add_argument("--scale", type=int, default=0,
                        help="手动指定缩放因子 N（跳过自动检测）")
    parser.add_argument("--detect-only", action="store_true",
                        help="仅检测网格大小，不输出图片")

    args = parser.parse_args()

    input_path = Path(args.input_path)
    if not input_path.is_file():
        print(f"错误: 文件不存在 - {input_path}", file=sys.stderr)
        sys.exit(1)

    # ---- 打开图片 ----
    image = Image.open(input_path)
    orig_w, orig_h = image.size
    print(f"输入图片:       {input_path}")
    print(f"原始尺寸:       {orig_w}x{orig_h} 像素")

    # ---- 确定缩放因子 ----
    if args.scale > 0:
        scale_factor = args.scale
        print(f"缩放因子:       {scale_factor}x（手动指定）")
    else:
        scale_factor = detect_grid_size(image)
        print(f"检测到网格大小: {scale_factor}x{scale_factor} 像素")

    target_w = orig_w // scale_factor
    target_h = orig_h // scale_factor
    print(f"目标尺寸:       {target_w}x{target_h} 像素")

    if scale_factor <= 1:
        print("图片已经是 1:1 像素，无需压缩。")
        if args.detect_only:
            return
        # 仍然输出一份副本
    else:
        # 检查原图尺寸是否能被整除
        if orig_w % scale_factor != 0 or orig_h % scale_factor != 0:
            print(f"警告: 原图尺寸 {orig_w}x{orig_h} 不能被 {scale_factor} 整除，"
                  f"边缘可能会丢失 {orig_w % scale_factor}/{orig_h % scale_factor} 像素")

    if args.detect_only:
        return

    # ---- 执行缩放 ----
    result = downscale_pixel_art(image, scale_factor)

    # ---- 生成输出路径 ----
    if args.output_path:
        output_path = Path(args.output_path)
    else:
        output_path = input_path.parent / f"{input_path.stem}_1x{input_path.suffix}"

    result.save(output_path)
    print(f"输出路径:       {output_path}")


if __name__ == "__main__":
    main()
