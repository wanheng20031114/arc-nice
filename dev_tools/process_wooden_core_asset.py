#!/usr/bin/env python3
"""Build and audit the 32x32 Wooden Core material icon."""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    TRANSPARENT,
    _key_magenta_source,
    clean_transparency,
    normalize_imagegen_subject,
    portable_path,
    source_audit,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_MASTER = (
    ROOT
    / "dev_assets/source_images/materials/wooden_core"
    / "wooden_core_selected_imagegen_magenta.png"
)
ALPHA_SOURCE = (
    ROOT
    / "dev_assets/source_images/materials/wooden_core"
    / "wooden_core_selected_alpha.png"
)
LOGICAL_OUTPUT = (
    ROOT
    / "dev_assets/source_images/materials/wooden_core"
    / "wooden_core_logical_preview.png"
)
OUTPUT = ROOT / "resources/texture/materials/wooden_core.png"
AUDIT_OUTPUT = (
    ROOT
    / "dev_assets/source_images/materials/wooden_core"
    / "wooden_core_asset_audit.json"
)

CANVAS_SIZE = (32, 32)
REVIEWED_LOGICAL_SIZE = (30, 31)


def main() -> None:
    if not SOURCE_MASTER.is_file():
        raise FileNotFoundError(SOURCE_MASTER)

    alpha_source = _key_magenta_source(SOURCE_MASTER)
    subject = normalize_imagegen_subject(
        SOURCE_MASTER,
        max_subject_size=REVIEWED_LOGICAL_SIZE,
        fit_oversized=False,
    )
    if subject.detected_logical_size != REVIEWED_LOGICAL_SIZE:
        raise RuntimeError(
            "Wooden Core source grid changed: "
            f"expected {REVIEWED_LOGICAL_SIZE}, "
            f"detected {subject.detected_logical_size}"
        )

    # The selected first draft already fits the 32x32 contract at 30x31.
    # Preserve every measured logical-cell sample exactly: no second resize,
    # no palette quantization, and no visual-density reduction.
    logical = clean_transparency(subject.image)
    if logical.size != REVIEWED_LOGICAL_SIZE:
        raise RuntimeError(
            f"Wooden Core logical output must be {REVIEWED_LOGICAL_SIZE}, "
            f"got {logical.size}"
        )

    output = Image.new("RGBA", CANVAS_SIZE, TRANSPARENT)
    paste_origin = (
        (CANVAS_SIZE[0] - logical.width) // 2,
        (CANVAS_SIZE[1] - logical.height) // 2,
    )
    output.alpha_composite(logical, paste_origin)
    output = clean_transparency(output)

    placed_logical = output.crop(
        (
            paste_origin[0],
            paste_origin[1],
            paste_origin[0] + logical.width,
            paste_origin[1] + logical.height,
        )
    )
    output_bbox = output.getchannel("A").getbbox()
    alpha_values = sorted(set(output.getchannel("A").getdata()))
    visible_colors = {
        (red, green, blue)
        for red, green, blue, alpha in output.getdata()
        if alpha > 0
    }
    transparent_rgb_clean = all(
        alpha > 0 or (red, green, blue) == (0, 0, 0)
        for red, green, blue, alpha in output.getdata()
    )
    checks = {
        "canvas_32x32": output.size == CANVAS_SIZE,
        "reviewed_subject_30x31": logical.size == REVIEWED_LOGICAL_SIZE,
        "subject_within_32x32": (
            output_bbox is not None
            and output_bbox[2] - output_bbox[0] <= CANVAS_SIZE[0]
            and output_bbox[3] - output_bbox[1] <= CANVAS_SIZE[1]
        ),
        "binary_alpha": set(alpha_values).issubset({0, 255}),
        "transparent_rgb_clean": transparent_rgb_clean,
        "logical_pixels_preserved_without_quantization": (
            placed_logical.tobytes() == logical.tobytes()
        ),
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise RuntimeError("; ".join(failures))

    report = {
        "schema_version": 2,
        "asset": "wooden_core",
        "status": "passed",
        "pipeline": [
            "built-in imagegen reference-guided first draft selected by user",
            "flat #FF00FF chroma-key removal",
            "pixel_grid_analyzer.py confirmed a 30x31 logical subject",
            "measured logical-cell center sampling at the detected 30x31 grid",
            "no palette quantization and no secondary logical resize",
            "binary-alpha 32x32 canvas audit",
        ],
        "source_master": portable_path(SOURCE_MASTER),
        "alpha_source": portable_path(ALPHA_SOURCE),
        "logical_output": portable_path(LOGICAL_OUTPUT),
        "output": portable_path(OUTPUT),
        "source": source_audit(subject),
        "logical_subject_size": list(logical.size),
        "paste_origin": list(paste_origin),
        "output_subject_bbox_exclusive": list(output_bbox),
        "visible_color_count": len(visible_colors),
        "alpha_values": alpha_values,
        "checks": checks,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    ALPHA_SOURCE.parent.mkdir(parents=True, exist_ok=True)
    alpha_source.save(ALPHA_SOURCE, format="PNG", optimize=True, compress_level=9)
    logical.save(LOGICAL_OUTPUT, format="PNG", optimize=True, compress_level=9)
    output.save(OUTPUT, format="PNG", optimize=True, compress_level=9)
    AUDIT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Wooden Core icon: {OUTPUT}")
    print(f"Audit report: {AUDIT_OUTPUT}")


if __name__ == "__main__":
    main()
