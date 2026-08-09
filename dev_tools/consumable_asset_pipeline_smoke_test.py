#!/usr/bin/env python3
"""Lightweight contract coverage for the consumable icon pipeline."""

from __future__ import annotations

from PIL import Image

from process_consumable_assets import (
    ASSETS,
    CANVAS_SIZE,
    TRANSPARENT,
    _audit_output,
    _center_on_canvas,
    _nearest_upscale_to_contract,
    plan_payload,
)


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _expect_runtime_error(callback, expected_fragment: str) -> None:
    try:
        callback()
    except RuntimeError as error:
        _expect(expected_fragment in str(error), f"Unexpected rejection: {error}")
        return
    raise AssertionError("Expected the invalid icon contract to be rejected")


def _make_subject(size: tuple[int, int]) -> Image.Image:
    subject = Image.new("RGBA", size, (20, 36, 52, 255))
    subject.putpixel((size[0] // 2, size[1] // 2), (72, 196, 240, 255))
    return subject


def main() -> None:
    slugs = [spec.slug for spec in ASSETS]
    _expect(len(ASSETS) == 12, "The approved expansion must contain exactly 12 assets")
    _expect(len(slugs) == len(set(slugs)), "Asset slugs must be unique")
    _expect(
        all(max(spec.max_subject_size) <= 30 for spec in ASSETS),
        "Every logical subject cap must retain a one-pixel transparent border",
    )
    _expect(
        all(
            spec.source_path.name.startswith(f"{spec.slug}_imagegen_magenta")
            and spec.source_path.suffix == ".png"
            for spec in ASSETS
        ),
        "Approved masters must use the rebuildable per-item versioned naming convention",
    )
    _expect(
        all(spec.output_path.name == f"{spec.slug}.png" for spec in ASSETS),
        "Production textures must use the canonical item slug",
    )

    subject = _make_subject((30, 30))
    output, origin = _center_on_canvas(subject)
    checks, bbox = _audit_output(output, subject, origin)
    _expect(output.size == CANVAS_SIZE, "Centered output must be 32x32")
    _expect(origin == (1, 1), "A 30x30 subject must be centered at 1,1")
    _expect(bbox == (1, 1, 31, 31), "The full 30x30 subject bbox must be retained")
    _expect(all(checks.values()), f"Valid synthetic icon failed: {checks}")

    sparse = _make_subject((10, 18))
    enlarged, scale = _nearest_upscale_to_contract(sparse, (22, 30))
    _expect(enlarged.size == (17, 30), "Sparse small icon must fill the readable height")
    _expect(scale > 1.0, "Sparse source must record a production-only upscale")
    _expect(
        set(enlarged.getdata()) == set(sparse.getdata()),
        "Nearest upscale must retain exactly the authored pixel palette",
    )

    _expect_runtime_error(
        lambda: _center_on_canvas(_make_subject((31, 30))),
        "one-pixel border",
    )
    dirty = output.copy()
    dirty.putpixel((0, 0), (255, 0, 255, 255))
    _expect_runtime_error(
        lambda: _audit_output(dirty, subject, origin),
        "one_pixel_transparent_border",
    )

    payload = plan_payload()
    _expect(payload["asset_count"] == 12, "Plan payload must list all 12 assets")
    _expect(
        payload["contract"]["palette_quantization"] == "none"
        and payload["contract"]["unsafe_grid_compression"] is False,
        "The no-loss/no-unsafe-resize contract must remain explicit",
    )
    print("CONSUMABLE_ASSET_PIPELINE_SMOKE_TEST_OK")


if __name__ == "__main__":
    main()
