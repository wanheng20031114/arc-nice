#!/usr/bin/env python3
"""Build the audited 64px Vegetation Stake sprite from its imagegen master."""

from __future__ import annotations

import argparse
from collections import deque
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    CANVAS_SIDE,
    TRANSPARENT,
    WORLD_SCALE,
    alpha_bbox,
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
SOURCE_DIR = ROOT / "dev_assets/source_images/plant_defense/vegetation_stake"
DEFAULT_INPUT = SOURCE_DIR / "vegetation_stake_selected_imagegen_magenta.png"
OUTPUT_DIR = ROOT / "resources/texture/plant_defense/vegetation_stake"
AUDIT_PATH = SOURCE_DIR / "vegetation_stake_asset_audit.json"
# The selected square-core source is natively 22x30 logical pixels including
# three detached glow motes. Once those motes are delegated to particles, the
# connected opaque building is exactly 22x23 and needs no secondary downscale.
MAX_NORMALIZED_SOURCE_SIZE = (22, 30)
MAX_SUBJECT_SIZE = (22, 23)
FOOT_TARGET = (32, 47)
MAX_VISIBLE_COLORS = 32


def _largest_component(image: Image.Image) -> tuple[Image.Image, dict]:
    """Keep the authored stake and leave detached motes to GPUParticles2D."""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    remaining = {
        (x, y)
        for y in range(rgba.height)
        for x in range(rgba.width)
        if pixels[x, y][3] > 0
    }
    components: list[set[tuple[int, int]]] = []
    while remaining:
        seed = remaining.pop()
        component = {seed}
        queue: deque[tuple[int, int]] = deque([seed])
        while queue:
            x, y = queue.popleft()
            for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    component.add(neighbor)
                    queue.append(neighbor)
        components.append(component)
    if not components:
        raise RuntimeError("Vegetation Stake imagegen source contains no subject")
    body = max(components, key=len)
    output = Image.new("RGBA", rgba.size, TRANSPARENT)
    target = output.load()
    for x, y in body:
        target[x, y] = pixels[x, y]
    return clean_transparency(output), {
        "component_count": len(components),
        "kept_body_pixels": len(body),
        "discarded_mote_pixels": sum(len(item) for item in components) - len(body),
        "reason": "detached authored motes are recreated by GPUParticles2D",
    }


def _build_glow_mask(image: Image.Image) -> Image.Image:
    """Extract the bright cap while excluding the lower white/gold housing."""
    rgba = image.convert("RGBA")
    left, top, right, bottom = alpha_bbox(rgba)
    cutoff_y = top + max(1, round((bottom - top) * 0.48))
    source = rgba.load()
    result = Image.new("RGBA", rgba.size, TRANSPARENT)
    target = result.load()
    for y in range(top, min(cutoff_y, bottom)):
        for x in range(left, right):
            red, green, blue, alpha = source[x, y]
            if alpha == 0:
                continue
            # The cap includes both saturated green rim pixels and its pale core.
            if green >= red * 0.82 and green >= blue * 1.03 and green >= 82:
                target[x, y] = (red, green, blue, 255)
    result = clean_transparency(result)
    if result.getchannel("A").getbbox() is None:
        raise RuntimeError("Vegetation Stake glow-mask extraction produced no pixels")
    return result


def build_assets(input_path: Path) -> tuple[dict[str, Image.Image], dict]:
    subject = normalize_imagegen_subject(
        input_path,
        max_subject_size=MAX_NORMALIZED_SOURCE_SIZE,
        fit_oversized=True,
    )
    body_subject, component_audit = _largest_component(subject.image)
    body_bbox = alpha_bbox(body_subject)
    body_subject = body_subject.crop(body_bbox)
    component_audit["opaque_body_size"] = list(body_subject.size)
    if body_subject.size != MAX_SUBJECT_SIZE:
        raise RuntimeError(
            "Vegetation Stake opaque body must remain exactly "
            f"{MAX_SUBJECT_SIZE[0]}x{MAX_SUBJECT_SIZE[1]} logical pixels; "
            f"got {body_subject.width}x{body_subject.height}"
        )
    registered, paste_origin = place_bottom_center(body_subject, target=FOOT_TARGET)
    palette = build_shared_palette([registered], max_colors=MAX_VISIBLE_COLORS)
    sprite = apply_palette(registered, palette)
    glow_mask = _build_glow_mask(sprite)
    return {"vegetation_stake": sprite, "vegetation_stake_glow": glow_mask}, {
        "source": source_audit(subject),
        "component_filter": component_audit,
        "registration": {
            "mode": "bottom_center",
            "paste_origin": list(paste_origin),
            "output_foot_target": list(FOOT_TARGET),
            "measured_output_foot_anchor": list(foot_anchor(sprite)),
        },
        "shared_palette": {
            "visible_color_limit": MAX_VISIBLE_COLORS,
            "actual_color_count": len(palette),
            "rgb": [list(color) for color in palette],
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    parser.add_argument("--audit-path", type=Path, default=AUDIT_PATH)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    assets, context = build_assets(args.input)
    outputs = [
        audit_image(
            image,
            label=name,
            path=portable_path(args.output_dir / f"{name}.png"),
            max_subject_size=MAX_SUBJECT_SIZE,
        )
        for name, image in assets.items()
    ]
    failures = validation_failures(outputs)
    report = {
        "schema_version": 1,
        "asset_family": "vegetation_stake",
        "status": "failed" if failures else "passed",
        "pipeline": [
            "built-in imagegen reference-guided master",
            "flat #FF00FF chroma key",
            "pixel_grid_analyzer measured logical grid",
            "nearest logical-cell selection",
            "detached motes delegated to GPUParticles2D",
            "shared <=32-color palette without dithering",
            "binary-alpha and footprint audit",
        ],
        "visual_contract": {
            "source_canvas_px": [CANVAS_SIDE, CANVAS_SIDE],
            "maximum_subject_px": list(MAX_SUBJECT_SIZE),
            "maximum_normalized_source_px": list(MAX_NORMALIZED_SOURCE_SIZE),
            "static_world_scale": [WORLD_SCALE, WORLD_SCALE],
            "camera_zoom": 2,
            "screen_px_per_source_px": 1,
            "floor_border_logical_px": 2,
            "inner_screen_px": [24, 24],
            "alpha": "binary",
            "transparent_rgb": [0, 0, 0],
            "visible_color_limit": MAX_VISIBLE_COLORS,
        },
        **context,
        "outputs": outputs,
        "validation": {"passed": not failures, "failures": failures},
    }
    if failures:
        raise RuntimeError("; ".join(failures))
    if args.check_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, image in assets.items():
        image.save(args.output_dir / f"{name}.png")
    args.audit_path.parent.mkdir(parents=True, exist_ok=True)
    args.audit_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Built Vegetation Stake assets: {args.output_dir}")
    print(f"Audit report: {args.audit_path}")


if __name__ == "__main__":
    main()
