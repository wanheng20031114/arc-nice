#!/usr/bin/env python3
"""Lightweight regression coverage for destructive pixel-pipeline guards."""

from __future__ import annotations

from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image

from build_collectible_icon_from_alpha import build_icon
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


def _make_thin_feature_grid_source() -> Image.Image:
    logical = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    pixels = logical.load()
    for x in range(2, 14):
        pixels[x, 8] = (216, 208, 180, 255)
    return logical.resize((64, 64), Image.Resampling.NEAREST)


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

    with TemporaryDirectory(prefix="arc_nice_pixel_guard_") as temporary_directory:
        temp_path = Path(temporary_directory)
        unknown_path = temp_path / "unknown.png"
        regular_path = temp_path / "regular.png"
        native_path = temp_path / "native_32.png"
        thin_feature_path = temp_path / "thin_feature.png"
        unknown_source.save(unknown_path)
        regular_source.save(regular_path)
        native_source.save(native_path)
        _make_thin_feature_grid_source().save(thin_feature_path)

        _expect_value_error(
            lambda: build_icon(unknown_path, temp_path / "rejected.png", 24, 12, 26),
            "Refusing high-resolution source",
        )
        _expect_value_error(
            lambda: build_icon(
                unknown_path,
                temp_path / "incomplete_grid_override.png",
                24,
                12,
                26,
                logical_grid_width=12,
            ),
            "must be provided together",
        )
        reviewed_override_result = build_icon(
            unknown_path,
            temp_path / "reviewed_grid_override.png",
            24,
            12,
            26,
            logical_grid_width=12,
            logical_grid_height=12,
        )
        _expect(
            reviewed_override_result["grid_selection"] == "explicit_reviewed_override"
            and reviewed_override_result["logical_grid_size"] == [12, 12]
            and reviewed_override_result["subject_grid_size"] == [12, 12],
            "A complete reviewed grid override must be recorded and honored",
        )
        regular_result = build_icon(
            regular_path,
            temp_path / "regular_output.png",
            24,
            12,
            26,
            palette=((11, 9, 13), (197, 29, 45), (255, 148, 0)),
        )
        _expect(
            regular_result["detection_mode"] == "exact_integer",
            "Collectible builder must accept a reliably gridded source",
        )
        _expect(
            (temp_path / "regular_output.png").is_file(),
            "Accepted regular-grid source must produce an output",
        )
        with Image.open(temp_path / "regular_output.png") as palette_output:
            visible_colors = {
                pixel[:3]
                for pixel in palette_output.convert("RGBA").getdata()
                if pixel[3] > 0
            }
        _expect(
            visible_colors <= {(11, 9, 13), (197, 29, 45), (255, 148, 0)},
            f"Palette-locked output leaked colors: {visible_colors}",
        )
        _expect(
            regular_result["palette"] == ["#0B090D", "#C51D2D", "#FF9400"],
            "Build manifest must preserve the exact palette contract",
        )
        build_icon(native_path, temp_path / "native_output.png", 24, 12, 26)
        _expect(
            (temp_path / "native_output.png").is_file(),
            "Native 32x32 source must remain supported by the collectible builder",
        )

        forced_boundary_path = temp_path / "thin_forced_boundary.png"
        authored_boundary_path = temp_path / "thin_authored_boundary.png"
        thin_palette = ((11, 13, 12), (216, 208, 180))
        forced_result = build_icon(
            thin_feature_path,
            forced_boundary_path,
            24,
            12,
            26,
            palette=thin_palette,
        )
        authored_result = build_icon(
            thin_feature_path,
            authored_boundary_path,
            24,
            12,
            26,
            palette=thin_palette,
            force_black_exterior_boundary=False,
        )
        with Image.open(forced_boundary_path) as forced_output:
            forced_visible_colors = {
                pixel[:3]
                for pixel in forced_output.convert("RGBA").getdata()
                if pixel[3] > 0
            }
        with Image.open(authored_boundary_path) as authored_output:
            authored_visible_colors = {
                pixel[:3]
                for pixel in authored_output.convert("RGBA").getdata()
                if pixel[3] > 0
            }
        _expect(
            forced_visible_colors == {(11, 13, 12)},
            f"Forced boundary mode must still darken a one-cell line: {forced_visible_colors}",
        )
        _expect(
            authored_visible_colors == {(216, 208, 180)},
            f"Authored boundary mode must preserve a one-cell line: {authored_visible_colors}",
        )
        _expect(
            forced_result["boundary_mode"] == "forced_black"
            and authored_result["boundary_mode"] == "authored",
            "Build manifest must record the selected boundary mode",
        )

    print("PIXEL_PIPELINE_GUARDRAILS_SMOKE_TEST_OK")


if __name__ == "__main__":
    main()
