#!/usr/bin/env python3
"""Lightweight contract coverage for the consumable icon pipeline."""

from __future__ import annotations

from PIL import Image

from process_consumable_assets import (
    ALL_ASSETS,
    ASSETS,
    CANVAS_SIZE,
    OUTER_BOUNDARY_COLOR,
    REPAIR_ASSETS,
    TRANSPARENT,
    _aligned_same_color_2x2_coverage,
    _audit_output,
    _center_on_canvas,
    _delete_logical_rows,
    _duplicate_logical_rows_after,
    _enforce_uniform_outer_boundary,
    _load_fresh_audit,
    _nearest_upscale_to_contract,
    _redraw_metrics,
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
    slugs = [spec.slug for spec in ALL_ASSETS]
    _expect(len(ASSETS) == 12, "The approved expansion must contain exactly 12 assets")
    _expect(
        len(REPAIR_ASSETS) == 1 and REPAIR_ASSETS[0].slug == "healing_potion",
        "The original healing potion must remain a repair outside the 12-item expansion",
    )
    _expect(len(ALL_ASSETS) == 13, "The build CLI must expose 12 new assets plus 1 repair")
    _expect(len(slugs) == len(set(slugs)), "Asset slugs must be unique")
    _expect(
        all(
            max(spec.expected_final_size or spec.max_subject_size) <= 30
            for spec in ALL_ASSETS
        ),
        "Every final logical subject must retain a one-pixel transparent border",
    )
    _expect(
        all(
            (
                spec.source_path.name.startswith(f"{spec.slug}_imagegen_magenta")
                or spec.source_path.name == spec.native_manual_master_filename
            )
            and spec.source_path.suffix == ".png"
            for spec in ALL_ASSETS
        ),
        "Approved masters must be versioned ImageGen sources or explicit native manual masters",
    )
    _expect(
        all(spec.output_path.name == f"{spec.slug}.png" for spec in ALL_ASSETS),
        "Production textures must use the canonical item slug",
    )

    redraw_specs = {
        spec.slug: spec
        for spec in ALL_ASSETS
        if spec.slug in {"battle_spirit_potion", "windwalk_potion", "healing_potion"}
    }
    _expect(
        {
            slug: (
                spec.expected_normalized_size,
                spec.logical_row_deletions,
                spec.logical_row_duplications_after,
                spec.expected_final_size,
                spec.forbid_production_upscale,
            )
            for slug, spec in redraw_specs.items()
        }
        == {
            "battle_spirit_potion": ((20, 31), (2,), (), (20, 30), True),
            "windwalk_potion": ((24, 32), (2, 10), (), (24, 30), True),
            "healing_potion": ((22, 28), (), (18, 20), (22, 30), True),
        },
        "The three native-density redraw recipes must remain exact and non-scaling",
    )

    striped = Image.new("RGBA", (8, 8), TRANSPARENT)
    for y in range(8):
        for x in range(2, 6):
            striped.putpixel((x, y), (40 + y, 70 + y, 100 + y, 255))
    edited = _delete_logical_rows(striped, (1, 5))
    _expect(edited.size == (8, 6), "Reviewed row deletion must remove rows without resizing")
    _expect(
        edited.getpixel((3, 1)) == striped.getpixel((3, 2))
        and edited.getpixel((3, 4)) == striped.getpixel((3, 6)),
        "Retained logical rows must remain byte-identical and in order",
    )
    duplicated = _duplicate_logical_rows_after(edited, (2, 4))
    _expect(duplicated.size == (8, 8), "Reviewed row duplication must add native rows")
    _expect(
        duplicated.getpixel((3, 2)) == duplicated.getpixel((3, 3))
        and duplicated.getpixel((3, 5)) == duplicated.getpixel((3, 6)),
        "Duplicated rows must remain byte-identical without resizing",
    )
    outlined, boundary = _enforce_uniform_outer_boundary(edited)
    _expect(
        all(outlined.getpixel(point) == OUTER_BOUNDARY_COLOR for point in boundary),
        "Only the reviewed silhouette boundary may receive the uniform outline colour",
    )
    metrics = _redraw_metrics(outlined, boundary)
    _expect(metrics["outer_boundary_dark_ratio"] == 1.0, "Outer outline must be uniform")
    _expect(
        _aligned_same_color_2x2_coverage(outlined) <= 0.25,
        "The synthetic native-density redraw must not look like an enlarged 16x16 sprite",
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
        payload["repair_asset_count"] == 1 and len(payload["assets"]) == 13,
        "Plan payload must expose the healing repair without changing expansion count",
    )
    _expect(
        all(_load_fresh_audit(spec) is not None for spec in ALL_ASSETS),
        "Every aggregate input audit must match the current source, PNG, prompt manifest, and processor",
    )
    _expect(
        payload["contract"]["palette_quantization"] == "none"
        and payload["contract"]["unsafe_grid_compression"] is False,
        "The no-loss/no-unsafe-resize contract must remain explicit",
    )
    print("CONSUMABLE_ASSET_PIPELINE_SMOKE_TEST_OK")


if __name__ == "__main__":
    main()
