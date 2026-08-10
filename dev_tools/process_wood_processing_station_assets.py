#!/usr/bin/env python3
"""Build audited Wood Processing Station, production UI, and plank assets."""

from __future__ import annotations

import hashlib
import json
from io import BytesIO
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    TRANSPARENT,
    _key_magenta_source,
    apply_palette,
    audit_image,
    build_shared_palette,
    clean_transparency,
    foot_anchor,
    normalize_imagegen_subject,
    place_bottom_center,
    portable_path,
    source_audit,
    validation_failures,
)


ROOT = Path(__file__).resolve().parents[1]
BUILDING_SOURCE = (
    ROOT
    / "dev_assets/source_images/plant_defense/wood_processing_station"
    / "wood_processing_station_selected_imagegen_magenta_v4.png"
)
PANEL_SOURCE = (
    ROOT
    / "dev_assets/source_images/plant_defense/wood_processing_station"
    / "production_panel_background_imagegen.png"
)
PLANK_SOURCE = (
    ROOT
    / "dev_assets/source_images/materials/plank"
    / "plank_selected_imagegen_magenta_v4.png"
)
BUILDING_OUTPUT = (
    ROOT
    / "resources/texture/plant_defense/wood_processing_station"
    / "wood_processing_station.png"
)
PANEL_OUTPUT = ROOT / "resources/texture/production/production_panel_background.png"
PLANK_OUTPUT = ROOT / "resources/texture/materials/plank.png"
AUDIT_OUTPUT = (
    ROOT
    / "dev_tools/output/plant_defense/wood_processing_station_asset_audit.json"
)

BUILDING_MAX_SIZE = (30, 31)
BUILDING_FOOT_TARGET = (32, 47)
BUILDING_COLOR_LIMIT = 48
PLANK_LOGICAL_SIZE = (29, 26)
PLANK_COLOR_LIMIT = 8
PLANK_CANVAS_SIZE = (32, 32)
PANEL_SIZE = (728, 544)


def _build_building() -> tuple[Image.Image, dict]:
    subject = normalize_imagegen_subject(
        BUILDING_SOURCE,
        max_subject_size=BUILDING_MAX_SIZE,
        fit_oversized=False,
    )
    registered, paste_origin = place_bottom_center(
        subject.image,
        target=BUILDING_FOOT_TARGET,
    )
    palette = build_shared_palette([registered], max_colors=BUILDING_COLOR_LIMIT)
    output = apply_palette(registered, palette)
    return output, {
        "source": source_audit(subject),
        "paste_origin": list(paste_origin),
        "foot_target": list(BUILDING_FOOT_TARGET),
        "measured_foot_anchor": list(foot_anchor(output)),
        "oversized_source_policy": "reject_and_regenerate_without_logical_resize",
        "visible_palette_size": len(palette),
    }


def _build_plank() -> tuple[Image.Image, dict]:
    keyed = _key_magenta_source(PLANK_SOURCE)
    bbox = keyed.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Plank chroma-key source contains no visible subject")
    cropped = keyed.crop(bbox)
    # The generated master was reviewed as one intact board whose diagonal
    # silhouette needs a near-full 32x32 footprint for inventory readability.
    # Sample it directly into the reviewed 29x26 target grid so the source
    # aspect ratio and hard pixel edges survive without filtered scaling.
    logical = cropped.resize(PLANK_LOGICAL_SIZE, Image.Resampling.NEAREST)
    logical = clean_transparency(logical)
    palette = build_shared_palette([logical], max_colors=PLANK_COLOR_LIMIT)
    logical = apply_palette(logical, palette)
    output = Image.new("RGBA", PLANK_CANVAS_SIZE, TRANSPARENT)
    paste_origin = (
        (PLANK_CANVAS_SIZE[0] - logical.width) // 2,
        (PLANK_CANVAS_SIZE[1] - logical.height) // 2,
    )
    output.alpha_composite(logical, paste_origin)
    output = clean_transparency(output)
    return output, {
        "source_path": portable_path(PLANK_SOURCE),
        "source_subject_bbox": list(bbox),
        "source_subject_size": list(cropped.size),
        "reviewed_visual_grid": list(PLANK_LOGICAL_SIZE),
        "normalization_mode": "manual_visual_grid_center_sample",
        "paste_origin": list(paste_origin),
        "visible_palette_size": len(palette),
    }


def _lossless_png_payload(image: Image.Image) -> tuple[bytes, dict]:
    baseline_buffer = BytesIO()
    image.save(baseline_buffer, format="PNG")
    baseline_payload = baseline_buffer.getvalue()

    optimized_buffer = BytesIO()
    image.save(
        optimized_buffer,
        format="PNG",
        optimize=True,
        compress_level=9,
    )
    optimized_payload = optimized_buffer.getvalue()

    baseline_decoded = Image.open(BytesIO(baseline_payload)).convert("RGBA").tobytes()
    optimized_decoded = Image.open(BytesIO(optimized_payload)).convert("RGBA").tobytes()
    pixel_identical = baseline_decoded == optimized_decoded
    if not pixel_identical:
        raise RuntimeError("Lossless plank PNG optimization changed decoded pixels")

    selected_payload = (
        optimized_payload
        if len(optimized_payload) <= len(baseline_payload)
        else baseline_payload
    )
    return selected_payload, {
        "mode": "png_deflate_lossless",
        "baseline_bytes": len(baseline_payload),
        "optimized_bytes": len(optimized_payload),
        "selected_bytes": len(selected_payload),
        "saved_bytes": len(baseline_payload) - len(selected_payload),
        "decoded_rgba_sha256": hashlib.sha256(baseline_decoded).hexdigest(),
        "pixel_identical": pixel_identical,
    }


def _build_panel() -> Image.Image:
    with Image.open(PANEL_SOURCE) as source:
        panel = source.convert("RGB")
    aspect_ratio = panel.width / panel.height
    if not 1.32 <= aspect_ratio <= 1.35:
        raise RuntimeError(
            f"Production panel master must remain approximately 4:3, got {panel.size}"
        )
    panel = panel.resize(PANEL_SIZE, Image.Resampling.NEAREST)
    return panel.quantize(
        colors=128,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")


def main() -> None:
    building, building_context = _build_building()
    plank, plank_context = _build_plank()
    plank_payload, plank_compression = _lossless_png_payload(plank)
    panel = _build_panel()
    building_audit = audit_image(
        building,
        label="wood_processing_station",
        path=portable_path(BUILDING_OUTPUT),
        max_subject_size=BUILDING_MAX_SIZE,
    )
    failures = validation_failures([building_audit])
    plank_alpha = sorted(set(plank.getchannel("A").getdata()))
    if plank.size != PLANK_CANVAS_SIZE:
        failures.append("plank canvas must be 32x32")
    if any(value not in (0, 255) for value in plank_alpha):
        failures.append("plank alpha must be binary")
    if panel.size != PANEL_SIZE:
        failures.append("production panel must be 728x544")

    report = {
        "schema_version": 1,
        "asset_family": "wood_processing_station",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen reference-guided masters",
            "flat #FF00FF chroma key",
            "project pixel-grid review and nearest logical-cell sampling",
            "oversized building sources rejected instead of fitted",
            "palette reduction without dithering",
            "binary-alpha and footprint audit",
        ],
        "building": {**building_context, "audit": building_audit},
        "plank": {
            **plank_context,
            "lossless_compression": plank_compression,
            "output_path": portable_path(PLANK_OUTPUT),
            "canvas_size": list(plank.size),
            "alpha_values": plank_alpha,
        },
        "production_panel": {
            "source_path": portable_path(PANEL_SOURCE),
            "output_path": portable_path(PANEL_OUTPUT),
            "output_size": list(panel.size),
            "visible_color_limit": 128,
        },
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))

    BUILDING_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    PANEL_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    PLANK_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    building.save(BUILDING_OUTPUT)
    panel.save(PANEL_OUTPUT)
    PLANK_OUTPUT.write_bytes(plank_payload)
    AUDIT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Wood Processing Station assets: {BUILDING_OUTPUT}")
    print(f"Built reusable production panel: {PANEL_OUTPUT}")
    print(f"Built plank material icon: {PLANK_OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
