#!/usr/bin/env python3
"""Build three 32x32 enemy material icons from approved imagegen masters.

The approved native-transparent ImageGen images are authoritative for both the
interior pixels and the refined silhouette. Each source is sampled once per
visually audited logical grid cell, centered on a transparent 32x32 canvas,
and checked against the previous mechanical 2x-reference-mask regression.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image
from plant_pixel_asset_pipeline import (
    TRANSPARENT,
    clean_transparency,
    portable_path,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "dev_assets/source_images/material_drops"
OUTPUT_ROOT = ROOT / "resources/texture/materials"
AUDIT_PATH = ROOT / "dev_tools/output/material_drops/material_drop_asset_audit.json"
CANVAS_SIZE = (32, 32)
MAX_SUBJECT_SIZE = (30, 30)
MAX_VISIBLE_COLORS = 32
MAX_LOGICAL_CELL_ASPECT_RATIO = 1.16

# These masks describe the superseded outputs only.  They are retained as a
# negative regression fixture: final icons must not collapse back to an exact
# 2x expansion of these coarse reference silhouettes.
LEGACY_CRYSTAL_MASK_ROWS = (
    "..###...",
    ".#####..",
    "#######.",
    "########",
    "########",
    "########",
    "########",
    "########",
    "########",
    "########",
    "########",
    ".######.",
    "..####..",
    "...##...",
)
LEGACY_POWDER_MASK_ROWS = (
    ".....##.....",
    "....####....",
    "...######...",
    "..########..",
    ".##########.",
    "############",
    "############",
    "############",
    ".##########.",
    "..########..",
    "....####....",
)

ASSETS = (
    {
        "id": "capoo_blue_crystal",
        "reference": SOURCE_ROOT / "capoo_blue_crystal_reference.png",
        "source": SOURCE_ROOT / "capoo_blue_crystal_alpha.png",
        "approved_master_sha256": "4fc371869b35d67454a2ef385a01e1b9591894f4cdc82194d93d7ebd9da8eb03",
        "logical": SOURCE_ROOT / "capoo_blue_crystal_logical_preview.png",
        "output": OUTPUT_ROOT / "capoo_blue_crystal.png",
        "approved_logical_size": (12, 25),
        "legacy_mask_rows": LEGACY_CRYSTAL_MASK_ROWS,
        "color_family": "blue",
        "grid_note": (
            "Pixel-grid analyzer: 12x25, confidence 0.931; the generated "
            "crystal edge is the approved authoritative silhouette."
        ),
    },
    {
        "id": "white_crystal",
        "reference": SOURCE_ROOT / "white_crystal_reference.png",
        "source": SOURCE_ROOT / "white_crystal_alpha.png",
        "approved_master_sha256": "5fa298fe470a088c8e1a431966bfb0caa00a41b8c76db79c3a1a517bd94fc484",
        "logical": SOURCE_ROOT / "white_crystal_logical_preview.png",
        "output": OUTPUT_ROOT / "white_crystal.png",
        "approved_logical_size": (16, 29),
        "legacy_mask_rows": LEGACY_CRYSTAL_MASK_ROWS,
        "color_family": "white",
        "grid_note": (
            "Pixel-grid analyzer: 16x29, confidence 0.856; manual boundary "
            "count confirms all 16 columns and 29 rows must be retained."
        ),
    },
    {
        "id": "sorcerer_violet_powder",
        "reference": SOURCE_ROOT / "reserved_pale_blue_powder_reference.png",
        "source": SOURCE_ROOT / "sorcerer_violet_powder_alpha.png",
        "approved_master_sha256": "bced5003720d98927d393668863365ace80589a784118fc6a362780d22b00766",
        "logical": SOURCE_ROOT / "sorcerer_violet_powder_logical_preview.png",
        "output": OUTPUT_ROOT / "sorcerer_violet_powder.png",
        "approved_logical_size": (18, 16),
        "legacy_mask_rows": LEGACY_POWDER_MASK_ROWS,
        "color_family": "violet",
        "grid_note": (
            "Pixel-grid analyzer: 18x16, confidence 0.974; the generated "
            "powder-mound edge is the approved authoritative silhouette."
        ),
    },
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source_file:
        for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _mask_sha256(image: Image.Image) -> str:
    alpha = image.convert("RGBA").getchannel("A")
    return hashlib.sha256(alpha.tobytes()).hexdigest()


def _validate_approved_sources() -> None:
    for spec in ASSETS:
        expected_source_sha = spec["approved_master_sha256"]
        actual_source_sha = _sha256(spec["source"])
        if actual_source_sha != expected_source_sha:
            raise RuntimeError(
                f"Approved imagegen master drifted for {spec['id']}: "
                f"expected {expected_source_sha}, got {actual_source_sha}"
            )
def _validate_transparent_source(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(path)
    with Image.open(path) as opened:
        image = opened.convert("RGBA")
    bbox = image.getchannel("A").getbbox()
    corners = (
        image.getpixel((0, 0))[3],
        image.getpixel((image.width - 1, 0))[3],
        image.getpixel((0, image.height - 1))[3],
        image.getpixel((image.width - 1, image.height - 1))[3],
    )
    if (
        bbox is None
        or bbox == (0, 0, image.width, image.height)
        or any(alpha != 0 for alpha in corners)
    ):
        raise RuntimeError(
            f"Native transparent source validation failed for {path}: "
            f"bbox={bbox}, corners={corners}"
        )
    return {
        "path": portable_path(path),
        "bbox": list(bbox),
        "transparent_corners": True,
    }


def _sample_approved_master(
    source_path: Path,
    approved_logical_size: tuple[int, int],
) -> tuple[Image.Image, Image.Image, dict]:
    """Sample one final pixel per approved imagegen logical cell."""
    with Image.open(source_path) as opened:
        source = clean_transparency(opened)
    analysis = analyze_image(source)
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError(
            f"Approved transparent ImageGen source is empty: {source_path}"
        )

    logical_width, logical_height = approved_logical_size
    if (
        logical_width > MAX_SUBJECT_SIZE[0]
        or logical_height > MAX_SUBJECT_SIZE[1]
    ):
        raise RuntimeError(
            f"Approved logical subject {approved_logical_size} exceeds "
            f"{MAX_SUBJECT_SIZE}: {source_path}"
        )

    subject_width = bbox[2] - bbox[0]
    subject_height = bbox[3] - bbox[1]
    logical_cell_width = subject_width / logical_width
    logical_cell_height = subject_height / logical_height
    logical_cell_aspect_ratio = max(
        logical_cell_width,
        logical_cell_height,
    ) / min(logical_cell_width, logical_cell_height)
    if logical_cell_aspect_ratio > MAX_LOGICAL_CELL_ASPECT_RATIO:
        raise RuntimeError(
            f"Approved grid {approved_logical_size} does not describe near-"
            f"square source cells for {source_path}: "
            f"{logical_cell_width:.3f}x{logical_cell_height:.3f}"
        )

    subject = source.crop(bbox).resize(
        approved_logical_size,
        Image.Resampling.NEAREST,
    )
    subject = clean_transparency(subject)
    if subject.getchannel("A").getbbox() != (
        0,
        0,
        logical_width,
        logical_height,
    ):
        raise RuntimeError(
            "Approved master sampling lost an outer logical edge: "
            f"{source_path}"
        )

    grid_audit = {
        "analysis": analysis,
        "source_subject_bbox": list(bbox),
        "approved_logical_size": list(approved_logical_size),
        "logical_cell_width": round(logical_cell_width, 3),
        "logical_cell_height": round(logical_cell_height, 3),
        "logical_cell_aspect_ratio": round(
            logical_cell_aspect_ratio,
            3,
        ),
    }
    return subject, source, grid_audit


def _compact_pixel_palette(image: Image.Image) -> Image.Image:
    alpha = image.getchannel("A")
    quantized = image.quantize(
        colors=MAX_VISIBLE_COLORS,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.NONE,
    ).convert("RGBA")
    quantized.putalpha(alpha)
    return clean_transparency(quantized)


def _visible_rgb(image: Image.Image) -> list[tuple[int, int, int]]:
    return [
        (red, green, blue)
        for red, green, blue, alpha in image.convert("RGBA").getdata()
        if alpha > 0
    ]


def _has_expected_color_family(
    visible_colors: list[tuple[int, int, int]],
    color_family: str,
) -> bool:
    if not visible_colors:
        return False
    mean_red = sum(color[0] for color in visible_colors) / len(visible_colors)
    mean_green = sum(color[1] for color in visible_colors) / len(visible_colors)
    mean_blue = sum(color[2] for color in visible_colors) / len(visible_colors)
    mean_luminance = (
        mean_red * 0.2126 + mean_green * 0.7152 + mean_blue * 0.0722
    )
    if color_family == "blue":
        return mean_blue > mean_red + 30.0 and mean_green > mean_red + 20.0
    if color_family == "white":
        return mean_luminance > 145.0 and min(
            mean_red,
            mean_green,
            mean_blue,
        ) > 120.0
    if color_family == "violet":
        return mean_blue > mean_green + 35.0 and mean_red > mean_green + 15.0
    return False


def _center_on_canvas(
    subject: Image.Image,
) -> tuple[Image.Image, tuple[int, int]]:
    if subject.width > CANVAS_SIZE[0] or subject.height > CANVAS_SIZE[1]:
        raise RuntimeError(
            f"Approved subject {subject.size} exceeds {CANVAS_SIZE}"
        )
    origin = (
        (CANVAS_SIZE[0] - subject.width) // 2,
        (CANVAS_SIZE[1] - subject.height) // 2,
    )
    canvas = Image.new("RGBA", CANVAS_SIZE, TRANSPARENT)
    canvas.alpha_composite(subject, origin)
    return clean_transparency(canvas), origin


def _build_legacy_2x_mask(mask_rows: tuple[str, ...]) -> Image.Image:
    native_width = len(mask_rows[0])
    native = Image.new(
        "RGBA",
        (native_width, len(mask_rows)),
        TRANSPARENT,
    )
    for y, row in enumerate(mask_rows):
        if len(row) != native_width:
            raise RuntimeError("Legacy mask rows have inconsistent widths")
        for x, marker in enumerate(row):
            if marker == "#":
                native.putpixel((x, y), (255, 255, 255, 255))
    mechanical_2x = native.resize(
        (native.width * 2, native.height * 2),
        Image.Resampling.NEAREST,
    )
    canvas, _origin = _center_on_canvas(mechanical_2x)
    return canvas


def _count_mixed_2x_alpha_blocks(subject: Image.Image) -> int:
    alpha = subject.getchannel("A")
    mixed_blocks = 0
    for top in range(0, subject.height - 1, 2):
        for left in range(0, subject.width - 1, 2):
            values = {
                alpha.getpixel((left + offset_x, top + offset_y))
                for offset_y in range(2)
                for offset_x in range(2)
            }
            if len(values) > 1:
                mixed_blocks += 1
    return mixed_blocks


def _build_asset(spec: dict) -> tuple[dict, Image.Image]:
    for required_path in (
        spec["reference"],
        spec["source"],
    ):
        if not required_path.is_file():
            raise FileNotFoundError(required_path)

    source_audit = _validate_transparent_source(spec["source"])
    approved_subject, _source, grid_audit = _sample_approved_master(
        spec["source"],
        spec["approved_logical_size"],
    )
    final_subject = _compact_pixel_palette(approved_subject)
    output, paste_origin = _center_on_canvas(final_subject)

    expected_canvas, _expected_origin = _center_on_canvas(approved_subject)
    legacy_canvas = _build_legacy_2x_mask(spec["legacy_mask_rows"])
    visible_colors = _visible_rgb(output)
    alpha_values = sorted(set(output.getchannel("A").getdata()))
    mixed_2x_alpha_blocks = _count_mixed_2x_alpha_blocks(final_subject)
    checks = {
        "canvas_32x32": output.size == CANVAS_SIZE,
        "approved_logical_size_exact": (
            final_subject.size == spec["approved_logical_size"]
        ),
        "generated_master_alpha_authoritative": (
            output.getchannel("A").tobytes()
            == expected_canvas.getchannel("A").tobytes()
        ),
        "not_legacy_mechanical_2x_mask": (
            output.getchannel("A").tobytes()
            != legacy_canvas.getchannel("A").tobytes()
        ),
        "refined_edge_has_non_2x_steps": mixed_2x_alpha_blocks > 0,
        "binary_alpha": set(alpha_values).issubset({0, 255}),
        "transparent_rgb_clean": all(
            alpha > 0 or (red, green, blue) == (0, 0, 0)
            for red, green, blue, alpha in output.getdata()
        ),
        "corners_transparent": all(
            output.getpixel(position) == TRANSPARENT
            for position in (
                (0, 0),
                (CANVAS_SIZE[0] - 1, 0),
                (0, CANVAS_SIZE[1] - 1),
                (CANVAS_SIZE[0] - 1, CANVAS_SIZE[1] - 1),
            )
        ),
        "compact_refined_palette": (
            8 <= len(set(visible_colors)) <= MAX_VISIBLE_COLORS
        ),
        "expected_color_family": _has_expected_color_family(
            visible_colors,
            spec["color_family"],
        ),
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise RuntimeError(f"{spec['id']}: " + "; ".join(failures))

    spec["output"].parent.mkdir(parents=True, exist_ok=True)
    final_subject.save(
        spec["logical"],
        format="PNG",
        optimize=True,
        compress_level=9,
    )
    output.save(
        spec["output"],
        format="PNG",
        optimize=True,
        compress_level=9,
    )

    report = {
        "asset": spec["id"],
        "status": "passed",
        "identity_reference": portable_path(spec["reference"]),
        "approved_imagegen_master": portable_path(spec["source"]),
        "approval_record": "approved source hashes embedded in processor",
        "transparent_source_audit": source_audit,
        "logical_preview": portable_path(spec["logical"]),
        "output": portable_path(spec["output"]),
        "identity_reference_sha256": _sha256(spec["reference"]),
        "approved_master_sha256": _sha256(spec["source"]),
        "output_sha256": _sha256(spec["output"]),
        "grid_note": spec["grid_note"],
        "grid_audit": grid_audit,
        "final_subject_size": list(final_subject.size),
        "paste_origin": list(paste_origin),
        "output_bbox_exclusive": list(output.getchannel("A").getbbox()),
        "final_mask_sha256": _mask_sha256(output),
        "legacy_mechanical_mask_sha256": _mask_sha256(legacy_canvas),
        "mixed_2x_alpha_block_count": mixed_2x_alpha_blocks,
        "visible_color_count": len(set(visible_colors)),
        "alpha_values": alpha_values,
        "checks": checks,
    }
    return report, output


def _build_contact_preview(outputs: list[Image.Image]) -> Path:
    margin = 4
    gap = 4
    logical_width = margin * 2 + len(outputs) * 32 + (len(outputs) - 1) * gap
    logical_height = 40
    sheet = Image.new(
        "RGBA",
        (logical_width, logical_height),
        (30, 30, 30, 255),
    )
    for index, output in enumerate(outputs):
        sheet.alpha_composite(
            output,
            (margin + index * (32 + gap), 4),
        )
    preview = sheet.resize(
        (sheet.width * 8, sheet.height * 8),
        Image.Resampling.NEAREST,
    )
    preview_path = SOURCE_ROOT / "material_drop_contact_preview_8x.png"
    preview.save(
        preview_path,
        format="PNG",
        optimize=True,
        compress_level=9,
    )
    return preview_path


def main() -> None:
    _validate_approved_sources()
    built = [_build_asset(spec) for spec in ASSETS]
    results = [result for result, _output in built]
    outputs = [output for _result, output in built]
    preview_path = _build_contact_preview(outputs)
    report = {
        "schema_version": 3,
        "status": "passed",
        "approval_record": "approved source hashes embedded in processor",
        "pipeline": [
            "approved native-transparent ImageGen sources hash-locked in processor",
            "approved generated masters treated as silhouette authorities",
            "logical grid measured with pixel_grid_analyzer and manually audited",
            "one final pixel center-sampled per approved generated logical cell",
            "generated master silhouette retained instead of an old reference mask",
            "non-dithered 32-color pixel palette compaction",
            "centered placement on a transparent 32x32 canvas",
            "anti-regression check rejects the old mechanical 2x silhouettes",
            "alpha, palette, color-family, and transparent-RGB audit",
        ],
        "contact_preview": portable_path(preview_path),
        "assets": results,
    }
    AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    AUDIT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built {len(results)} generated-edge material-drop icons.")
    print(f"Preview: {preview_path}")
    print(f"Audit report: {AUDIT_PATH}")


if __name__ == "__main__":
    main()
