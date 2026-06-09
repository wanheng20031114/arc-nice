#!/usr/bin/env python3
"""
像素画网格分析工具。

支持两类输入：
1. 严格整数放大的像素画，每个逻辑像素占固定的 NxN 物理像素。
2. 生成式模型输出的近似像素画，格宽可能在 N/N+1 之间交替，格内也可能有渐变。

第二类图片不能对颜色游程直接求 GCD。本工具会统计透明轮廓和显著颜色边界的
周期相位，估算 X/Y 方向的逻辑格距，并给出推荐逻辑尺寸与置信度。

用法:
  python pixel_grid_analyzer.py <image_path>
  python pixel_grid_analyzer.py <image_path> --json
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import math
import sys
from pathlib import Path

from PIL import Image


def _pixel_value(pixel, has_alpha: bool):
    if isinstance(pixel, tuple):
        if has_alpha and len(pixel) >= 4 and pixel[3] == 0:
            return (0, 0, 0, 0)
        return pixel
    return (pixel,)


def find_subject_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    """返回主体边界框，right/bottom 为排他坐标。"""
    rgba = image.convert("RGBA")
    bbox = rgba.getchannel("A").getbbox()
    if bbox is not None:
        return bbox

    return (0, 0, image.width, image.height)


def _color_distance(a: tuple[int, ...], b: tuple[int, ...]) -> int:
    if len(a) >= 4 and a[3] == 0 and len(b) >= 4 and b[3] == 0:
        return 0
    return sum(abs(int(a[index]) - int(b[index])) for index in range(3))


def _detect_exact_integer_grid(image: Image.Image) -> int:
    """严格像素画优先走无损 GCD；出现渐变或抗锯齿时自然退化为 1。"""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    run_lengths: list[int] = []

    for y in range(rgba.height):
        previous = _pixel_value(pixels[0, y], True)
        run_start = 0
        for x in range(1, rgba.width):
            current = _pixel_value(pixels[x, y], True)
            if current != previous:
                run_lengths.append(x - run_start)
                run_start = x
                previous = current
        run_lengths.append(rgba.width - run_start)

    for x in range(rgba.width):
        previous = _pixel_value(pixels[x, 0], True)
        run_start = 0
        for y in range(1, rgba.height):
            current = _pixel_value(pixels[x, y], True)
            if current != previous:
                run_lengths.append(y - run_start)
                run_start = y
                previous = current
        run_lengths.append(rgba.height - run_start)

    result = 0
    for run_length in run_lengths:
        result = math.gcd(result, run_length)
        if result == 1:
            return 1

    return max(result, 1)


def _collect_edge_signal(
    image: Image.Image,
    axis: int,
    color_threshold: int = 42,
) -> list[float]:
    """
    把轮廓/显著颜色变化投影到一个坐标轴。

    alpha 边界权重较高；颜色变化只有超过阈值才计入，从而忽略格内轻微渐变。
    """
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    axis_length = rgba.width if axis == 0 else rgba.height
    cross_length = rgba.height if axis == 0 else rgba.width
    signal = [0.0] * axis_length

    for cross in range(cross_length):
        previous = pixels[0, cross] if axis == 0 else pixels[cross, 0]
        for position in range(1, axis_length):
            current = (
                pixels[position, cross]
                if axis == 0
                else pixels[cross, position]
            )
            previous_visible = previous[3] > 0
            current_visible = current[3] > 0

            if previous_visible != current_visible:
                signal[position] += 3.0
            elif current_visible and _color_distance(previous, current) >= color_threshold:
                signal[position] += 1.0

            previous = current

    return signal


def _period_phase_score(signal: list[float], period: float) -> float:
    """计算边界坐标对某一周期的圆形相位集中度，返回 0..1。"""
    total_weight = sum(signal)
    if total_weight <= 0.0:
        return 0.0

    real = 0.0
    imaginary = 0.0
    angular_scale = math.tau / period

    for coordinate, weight in enumerate(signal):
        if weight <= 0.0:
            continue
        angle = coordinate * angular_scale
        real += weight * math.cos(angle)
        imaginary += weight * math.sin(angle)

    return math.hypot(real, imaginary) / total_weight


def _estimate_axis_period(signal: list[float]) -> tuple[float, float]:
    """
    在合理范围内搜索边界周期。

    使用 0.05 像素步长是为了识别 20/21 像素交替形成的近似 20.2 像素网格。
    """
    axis_length = len(signal)
    if axis_length < 8 or sum(signal) <= 0.0:
        return (1.0, 0.0)

    max_signal = max(signal)
    prominent_coordinates = [
        coordinate
        for coordinate, weight in enumerate(signal)
        if weight >= max_signal * 0.04
    ]
    prominent_gaps = [
        current - previous
        for previous, current in zip(
            prominent_coordinates,
            prominent_coordinates[1:],
        )
        if 2 <= current - previous <= 128
    ]

    if prominent_gaps:
        spacing_hint = Counter(prominent_gaps).most_common(1)[0][0]
        min_period = max(2.0, spacing_hint * 0.6)
        max_period = min(128.0, axis_length / 2.0, spacing_hint * 1.4)
    else:
        min_period = 2.0
        max_period = min(128.0, axis_length / 2.0)
    scored_periods: list[tuple[float, float]] = []
    step = 0.05
    sample_count = int((max_period - min_period) / step) + 1

    for sample_index in range(sample_count):
        period = min_period + sample_index * step
        score = _period_phase_score(signal, period)
        scored_periods.append((period, score))

    return max(scored_periods, key=lambda item: item[1])


def analyze_image(image: Image.Image) -> dict:
    rgba = image.convert("RGBA")
    bbox = find_subject_bbox(rgba)
    cropped = rgba.crop(bbox)

    exact_grid_size = _detect_exact_integer_grid(rgba)
    if exact_grid_size > 1:
        x_period = float(exact_grid_size)
        y_period = float(exact_grid_size)
        confidence = 1.0
        detection_mode = "exact_integer"
    else:
        x_signal = _collect_edge_signal(cropped, 0)
        y_signal = _collect_edge_signal(cropped, 1)
        x_period, x_score = _estimate_axis_period(x_signal)
        y_period, y_score = _estimate_axis_period(y_signal)
        x_evidence = min(1.0, sum(value > 0.0 for value in x_signal) / 6.0)
        y_evidence = min(1.0, sum(value > 0.0 for value in y_signal) / 6.0)
        confidence = (x_score * x_evidence + y_score * y_evidence) * 0.5

        if confidence < 0.45:
            x_period = 1.0
            y_period = 1.0
            detection_mode = "native_or_unknown"
        else:
            detection_mode = "approximate"

    subject_width = bbox[2] - bbox[0]
    subject_height = bbox[3] - bbox[1]
    logical_width = max(1, round(subject_width / x_period))
    logical_height = max(1, round(subject_height / y_period))

    return {
        "image_width": rgba.width,
        "image_height": rgba.height,
        "image_mode": rgba.mode,
        "detection_mode": detection_mode,
        "grid_cell_width": round(x_period, 3),
        "grid_cell_height": round(y_period, 3),
        "grid_cell_size": max(1, round((x_period + y_period) * 0.5)),
        "confidence": round(confidence, 3),
        "subject_bbox": {
            "left": bbox[0],
            "top": bbox[1],
            "right": bbox[2],
            "bottom": bbox[3],
        },
        "subject_pixel_width": subject_width,
        "subject_pixel_height": subject_height,
        "subject_grid_width": logical_width,
        "subject_grid_height": logical_height,
        "recommended_canvas_grid_width": max(
            1, round(rgba.width / x_period)
        ),
        "recommended_canvas_grid_height": max(
            1, round(rgba.height / y_period)
        ),
    }


def detect_grid_size(image: Image.Image) -> int:
    """兼容旧调用：返回 X/Y 平均格距的最接近整数。"""
    return analyze_image(image)["grid_cell_size"]


def analyze(image_path: str) -> dict:
    image = Image.open(image_path)
    result = analyze_image(image)
    result["image_path"] = str(image_path)
    return result


def _print_human_readable(result: dict) -> None:
    bbox = result["subject_bbox"]
    print(f"图片路径:         {result['image_path']}")
    print(f"图片尺寸:         {result['image_width']}x{result['image_height']} 像素")
    print(f"图片模式:         {result['image_mode']}")
    print(f"检测模式:         {result['detection_mode']}")
    print(
        "估算网格单元:     "
        f"{result['grid_cell_width']}x{result['grid_cell_height']} 像素"
    )
    print(f"检测置信度:       {result['confidence']:.3f}")
    print(
        "主体边界框:       "
        f"({bbox['left']}, {bbox['top']}) -> ({bbox['right']}, {bbox['bottom']})"
    )
    print(
        "主体像素尺寸:     "
        f"{result['subject_pixel_width']}x{result['subject_pixel_height']} 像素"
    )
    print(
        "主体逻辑尺寸:     "
        f"{result['subject_grid_width']}x{result['subject_grid_height']} 格"
    )
    print(
        "建议画布尺寸:     "
        f"{result['recommended_canvas_grid_width']}x"
        f"{result['recommended_canvas_grid_height']} 格"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="分析像素画的逻辑网格")
    parser.add_argument("image_path", help="要分析的图片路径")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    args = parser.parse_args()

    if not Path(args.image_path).is_file():
        print(f"错误: 文件不存在 - {args.image_path}", file=sys.stderr)
        raise SystemExit(1)

    result = analyze(args.image_path)
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        _print_human_readable(result)


if __name__ == "__main__":
    main()
