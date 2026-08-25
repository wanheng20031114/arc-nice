#!/usr/bin/env python3
"""Lightweight regression coverage for destructive pixel-pipeline guards."""

from __future__ import annotations

from PIL import Image

from pixel_crop_tool import compress_to_logical_grid
from pixel_grid_analyzer import analyze_image


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _expect_value_error(callback, expected_fragment: str) -> None:
    try:
        callback()
    except ValueError as error:
        _expect(
            expected_fragment in str(error),
            f"Unexpected rejection message: {error}",
        )
        return
    raise AssertionError("Expected unsafe pixel source to be rejected")


def _make_unknown_high_resolution_source() -> Image.Image:
    image = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(12, 84):
        for x in range(12, 84):
            pixels[x, y] = (x * 2, y * 2, x + y, 255)
    return image


def _make_regular_grid_source() -> Image.Image:
    logical = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    pixels = logical.load()
    for y in range(2, 14):
        for x in range(2, 14):
            is_outline = x in (2, 13) or y in (2, 13)
            pixels[x, y] = (0, 0, 0, 255) if is_outline else (236, 176, 48, 255)
    for y in range(6, 10):
        for x in range(6, 10):
            pixels[x, y] = (224, 72, 48, 255)
    return logical.resize((64, 64), Image.Resampling.NEAREST)


def _make_native_32_source() -> Image.Image:
    image = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(8, 24):
        for x in range(8, 24):
            is_outline = x in (8, 23) or y in (8, 23)
            fill = (88, 136, 196, 255) if (x + y) % 2 == 0 else (192, 160, 72, 255)
            pixels[x, y] = (0, 0, 0, 255) if is_outline else fill
    return image


def main() -> None:
    unknown_source = _make_unknown_high_resolution_source()
    unknown_analysis = analyze_image(unknown_source)
    _expect(
        unknown_analysis["detection_mode"] == "native_or_unknown",
        f"Fixture must remain unresolved, got {unknown_analysis}",
    )
    _expect_value_error(
        lambda: compress_to_logical_grid(unknown_source, logical_size=32),
        "拒绝不可靠的逻辑网格压缩",
    )
    overridden, _analysis = compress_to_logical_grid(
        unknown_source,
        logical_size=32,
        allow_unsafe_grid_compression=True,
    )
    _expect(
        overridden.size == (32, 32),
        "The explicitly dangerous override must remain available for reviewed sources",
    )

    regular_source = _make_regular_grid_source()
    regular_analysis = analyze_image(regular_source)
    _expect(
        regular_analysis["detection_mode"] == "exact_integer",
        f"Fixture must retain an exact logical grid, got {regular_analysis}",
    )
    compressed, _analysis = compress_to_logical_grid(regular_source)
    _expect(compressed.size == (16, 16), "A 4x regular grid must normalize to 16x16")

    native_source = _make_native_32_source()
    native_result, _analysis = compress_to_logical_grid(native_source, logical_size=32)
    _expect(native_result.size == (32, 32), "Native 32x32 input must remain supported")

    print("PIXEL_PIPELINE_GUARDRAILS_SMOKE_TEST_OK")


if __name__ == "__main__":
    main()
