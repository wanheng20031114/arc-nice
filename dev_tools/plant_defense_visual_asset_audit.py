#!/usr/bin/env python3
"""Audit the 64px visual contract shared by plant-defense buildings.

The raw PNGs are inspected directly instead of through Godot's imported
textures.  This keeps transparent-RGB and palette checks meaningful: Godot's
alpha-border import processing is allowed to populate transparent texels in
the generated texture cache even when the source PNG is clean.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_ROOT = ROOT / "resources/texture/plant_defense"
SOURCE_SIDE = 64
WORLD_SCALE = 0.5
WORLD_FOOTPRINT_SIDE = 32.0
MAX_VISIBLE_COLORS = 64
WAREHOUSE_MAX_SUBJECT_SIZE = (60, 62)
PIVOT_IN_TEXTURE = (SOURCE_SIDE // 2, SOURCE_SIDE // 2)
AGAVE_HEAD_OFFSET = (0, -6)

WAREHOUSE_ASSET = TEXTURE_ROOT / "oak_warehouse/oak_warehouse.png"
AGAVE_ICON = TEXTURE_ROOT / "agave_cannon/icon.png"
AGAVE_BODY_FRAMES = tuple(
    TEXTURE_ROOT / f"agave_cannon/agave_body_idle_{index}.png"
    for index in range(4)
)
AGAVE_HEAD_FRAMES = (
    TEXTURE_ROOT / "agave_cannon/agave_cannon_idle_0.png",
    *(
        TEXTURE_ROOT / f"agave_cannon/agave_cannon_fire_{index}.png"
        for index in range(5)
    ),
)
BUILDING_ASSETS = (WAREHOUSE_ASSET, AGAVE_ICON, *AGAVE_BODY_FRAMES, *AGAVE_HEAD_FRAMES)


def _relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def _load_rgba(path: Path) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    with Image.open(path) as source:
        return source.convert("RGBA")


def _bbox_size(bbox: tuple[int, int, int, int] | None) -> tuple[int, int]:
    if bbox is None:
        return (0, 0)
    left, top, right, bottom = bbox
    return (right - left, bottom - top)


def _audit_png(path: Path) -> dict[str, Any]:
    image = _load_rgba(path)
    pixels = tuple(image.getdata())
    visible_colors = {pixel[:3] for pixel in pixels if pixel[3] == 255}
    alpha_values = {pixel[3] for pixel in pixels}
    bbox = image.getchannel("A").getbbox()
    world_bounds = None
    if bbox is not None:
        world_bounds = [
            round((bbox[0] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
            round((bbox[1] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
            round((bbox[2] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
            round((bbox[3] - SOURCE_SIDE * 0.5) * WORLD_SCALE, 3),
        ]
    maximum_radius_from_center = max(
        (
            math.hypot((x + 0.5) - PIVOT_IN_TEXTURE[0], (y + 0.5) - PIVOT_IN_TEXTURE[1])
            for y in range(image.height)
            for x in range(image.width)
            if image.getpixel((x, y))[3] == 255
        ),
        default=0.0,
    )
    import_text = path.with_suffix(path.suffix + ".import").read_text(encoding="utf-8")
    import_contract = {
        "lossless_compression": "compress/mode=0" in import_text,
        "mipmaps_disabled": "mipmaps/generate=false" in import_text,
        "premultiply_disabled": "process/premult_alpha=false" in import_text,
        "unlimited_source_size": "process/size_limit=0" in import_text,
    }
    return {
        "path": _relative(path),
        "size": list(image.size),
        "subject_bbox": list(bbox) if bbox is not None else None,
        "subject_size": list(_bbox_size(bbox)),
        "world_bounds_at_scale_0_5": world_bounds,
        "visible_color_count": len(visible_colors),
        "maximum_radius_from_canvas_center": round(maximum_radius_from_center, 3),
        "binary_alpha": alpha_values.issubset({0, 255}),
        "transparent_rgb_clean": all(
            alpha != 0 or (red == 0 and green == 0 and blue == 0)
            for red, green, blue, alpha in pixels
        ),
        "non_empty": bbox is not None,
        "import_contract": import_contract,
    }


def _footpoint(audit: dict[str, Any]) -> tuple[float, float]:
    bbox = audit["subject_bbox"]
    if bbox is None:
        return (0.0, 0.0)
    left, _top, right, bottom = bbox
    return ((left + right - 1) * 0.5, float(bottom - 1))


def _agave_default_recomposition_diff() -> int:
    body = _load_rgba(AGAVE_BODY_FRAMES[0])
    head = _load_rgba(AGAVE_HEAD_FRAMES[0])
    recomposed = body.copy()
    recomposed.alpha_composite(head, AGAVE_HEAD_OFFSET)
    icon = _load_rgba(AGAVE_ICON)
    return sum(
        recomposed_pixel != icon_pixel
        for recomposed_pixel, icon_pixel in zip(recomposed.getdata(), icon.getdata())
    )


def _collect_failures(report: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    audits = {entry["path"]: entry for entry in report["assets"]}
    for path in BUILDING_ASSETS:
        audit = audits[_relative(path)]
        if audit["size"] != [SOURCE_SIDE, SOURCE_SIDE]:
            failures.append(f"{audit['path']} must be exactly 64x64")
        if not audit["non_empty"]:
            failures.append(f"{audit['path']} must contain visible pixels")
        world_bounds = audit["world_bounds_at_scale_0_5"]
        if world_bounds is not None and not (
            world_bounds[0] >= -WORLD_FOOTPRINT_SIDE * 0.5
            and world_bounds[1] >= -WORLD_FOOTPRINT_SIDE * 0.5
            and world_bounds[2] <= WORLD_FOOTPRINT_SIDE * 0.5
            and world_bounds[3] <= WORLD_FOOTPRINT_SIDE * 0.5
        ):
            failures.append(
                f"{audit['path']} escapes the centered 32x32 world footprint"
            )
        if not audit["binary_alpha"]:
            failures.append(f"{audit['path']} contains non-binary alpha")
        if not audit["transparent_rgb_clean"]:
            failures.append(f"{audit['path']} contains RGB data in transparent texels")
        if audit["visible_color_count"] > MAX_VISIBLE_COLORS:
            failures.append(
                f"{audit['path']} uses {audit['visible_color_count']} visible colors; "
                f"maximum is {MAX_VISIBLE_COLORS}"
            )
        failed_import_keys = [
            key for key, passed in audit["import_contract"].items() if not passed
        ]
        if failed_import_keys:
            failures.append(
                f"{audit['path']} violates import contract: {', '.join(failed_import_keys)}"
            )

    warehouse = audits[_relative(WAREHOUSE_ASSET)]
    warehouse_width, warehouse_height = warehouse["subject_size"]
    if (
        warehouse_width > WAREHOUSE_MAX_SUBJECT_SIZE[0]
        or warehouse_height > WAREHOUSE_MAX_SUBJECT_SIZE[1]
    ):
        failures.append(
            "oak warehouse subject must fit within 60x62 source pixels; "
            f"got {warehouse_width}x{warehouse_height}"
        )

    body_audits = [audits[_relative(path)] for path in AGAVE_BODY_FRAMES]
    body_footpoints = [_footpoint(audit) for audit in body_audits]
    if body_footpoints:
        reference_x, reference_y = body_footpoints[0]
        for audit, (foot_x, foot_y) in zip(body_audits[1:], body_footpoints[1:]):
            if abs(foot_x - reference_x) > 1.0 or abs(foot_y - reference_y) > 1.0:
                failures.append(
                    f"{audit['path']} footpoint drifts more than one source pixel "
                    f"from ({reference_x}, {reference_y}) to ({foot_x}, {foot_y})"
                )

    for path in AGAVE_HEAD_FRAMES:
        audit = audits[_relative(path)]
        if audit["maximum_radius_from_canvas_center"] > 24.0:
            failures.append(
                f"{_relative(path)} exceeds the 24px radius around the shared 32,32 pivot"
            )

    if report["agave_default_recomposition_diff_pixels"] != 0:
        failures.append(
            "Agave runtime body/head composition must match its placement icon "
            "pixel-for-pixel at the default pivot"
        )

    return failures


def build_report() -> dict[str, Any]:
    asset_audits = [_audit_png(path) for path in BUILDING_ASSETS]
    audits = {entry["path"]: entry for entry in asset_audits}
    body_footpoints = {
        _relative(path): list(_footpoint(audits[_relative(path)]))
        for path in AGAVE_BODY_FRAMES
    }
    return {
        "contract": {
            "source_canvas": [SOURCE_SIDE, SOURCE_SIDE],
            "static_world_scale": WORLD_SCALE,
            "world_footprint": [WORLD_FOOTPRINT_SIDE, WORLD_FOOTPRINT_SIDE],
            "max_visible_colors": MAX_VISIBLE_COLORS,
            "warehouse_max_subject": list(WAREHOUSE_MAX_SUBJECT_SIZE),
            "agave_shared_head_pivot": list(PIVOT_IN_TEXTURE),
            "agave_max_body_footpoint_drift": 1.0,
        },
        "assets": asset_audits,
        "agave_body_footpoints": body_footpoints,
        "agave_default_recomposition_diff_pixels": _agave_default_recomposition_diff(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        type=Path,
        help="Optionally write the full JSON audit report to this path.",
    )
    args = parser.parse_args()

    report = build_report()
    failures = _collect_failures(report)
    report["passed"] = not failures
    report["failures"] = failures
    if args.report is not None:
        report_path = args.report
        if not report_path.is_absolute():
            report_path = ROOT / report_path
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}")
        raise SystemExit(1)
    print("PLANT_DEFENSE_VISUAL_ASSET_AUDIT_OK")


if __name__ == "__main__":
    main()
