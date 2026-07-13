#!/usr/bin/env python3
"""Shared, strict helpers for 64-logical-pixel plant building assets.

The helpers deliberately reject an imagegen source when its logical grid cannot
be measured reliably.  They never provide an ``allow unsafe`` escape hatch:
regenerating the source is safer than silently shrinking a continuous
illustration into a nominally 64px texture.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from PIL import Image

from connected_background_remover import (
    ConnectedBackgroundOptions,
    remove_connected_background,
)
from pixel_grid_analyzer import analyze_image
from pixel_grid_analyzer import _collect_edge_signal, _period_phase_score


CANVAS_SIDE = 64
WORLD_SCALE = 0.5
WORLD_FOOTPRINT_SIDE = 32
MAX_VISIBLE_COLORS = 64
MIN_SAFE_GRID_CONFIDENCE = 0.65
TRANSPARENT = (0, 0, 0, 0)
REPO_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class NormalizedSubject:
    image: Image.Image
    source_path: Path
    source_analysis: dict
    logical_size: tuple[int, int]
    detected_logical_size: tuple[int, int]
    logical_fit_scale: float
    normalization_mode: str


def clean_transparency(image: Image.Image) -> Image.Image:
    """Harden alpha and zero RGB for every transparent output pixel."""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            pixels[x, y] = (red, green, blue, 255) if alpha > 0 else TRANSPARENT
    return rgba


def _key_magenta_source(source_path: Path) -> Image.Image:
    keyed = remove_connected_background(
        Image.open(source_path),
        ConnectedBackgroundOptions(
            rgb_tolerance=72,
            hue_tolerance=0.035,
            expansion_radius=12,
            harden_alpha=True,
        ),
    )
    keyed = clean_transparency(keyed)
    if keyed.getchannel("A").getbbox() is None:
        raise RuntimeError(f"Chroma-key removal produced an empty image: {source_path}")
    return keyed


def normalize_imagegen_subject(
    source_path: Path,
    *,
    max_subject_size: tuple[int, int],
    fit_oversized: bool = True,
) -> NormalizedSubject:
    """Convert a keyed source into one native pixel per measured logical cell.

    Sources already no larger than 64x64 are preserved pixel-for-pixel.  Larger
    sources require a measured grid with confidence >= 0.65; an unknown grid is
    an actionable regeneration failure rather than permission to resize art.
    """
    if not source_path.is_file():
        raise FileNotFoundError(source_path)
    keyed = _key_magenta_source(source_path)
    analysis = analyze_image(keyed)
    bbox_dict = analysis["subject_bbox"]
    bbox = (
        int(bbox_dict["left"]),
        int(bbox_dict["top"]),
        int(bbox_dict["right"]),
        int(bbox_dict["bottom"]),
    )

    if keyed.width <= CANVAS_SIDE and keyed.height <= CANVAS_SIDE:
        logical_width = bbox[2] - bbox[0]
        logical_height = bbox[3] - bbox[1]
        normalization_mode = "native_64_or_smaller"
    else:
        confidence = float(analysis["confidence"])
        if (
            analysis["detection_mode"] == "native_or_unknown"
            or confidence < MIN_SAFE_GRID_CONFIDENCE
        ):
            fallback = _measure_periodic_pixel_grid(keyed.crop(bbox))
            if fallback is None:
                raise RuntimeError(
                    "Refusing unreliable logical-grid compression for "
                    f"{source_path}: mode={analysis['detection_mode']}, "
                    f"confidence={confidence:.3f}. Regenerate the imagegen "
                    "source; this pipeline intentionally has no unsafe override."
                )
            analysis = {**analysis, **fallback}
        logical_width = max(
            1,
            round((bbox[2] - bbox[0]) / float(analysis["grid_cell_width"])),
        )
        logical_height = max(
            1,
            round((bbox[3] - bbox[1]) / float(analysis["grid_cell_height"])),
        )
        normalization_mode = "measured_grid_center_sample"

    max_width, max_height = max_subject_size
    detected_logical_size = (logical_width, logical_height)
    fit_scale = min(1.0, max_width / logical_width, max_height / logical_height)
    if fit_scale < 1.0 and not fit_oversized:
        raise RuntimeError(
            f"Logical subject {logical_width}x{logical_height} exceeds the "
            f"{max_width}x{max_height} contract: {source_path}. Regenerate it "
            "with fewer logical pixels; do not downscale it again."
        )
    fitted_width = max(1, round(logical_width * fit_scale))
    fitted_height = max(1, round(logical_height * fit_scale))
    if fitted_width > max_width:
        fitted_width = max_width
    if fitted_height > max_height:
        fitted_height = max_height

    subject = keyed.crop(bbox)
    if subject.size != (logical_width, logical_height):
        # Pillow's nearest sampler selects one representative center per
        # measured logical cell.  There is no color averaging or smoothing.
        subject = subject.resize(
            (logical_width, logical_height),
            Image.Resampling.NEAREST,
        )
    if subject.size != (fitted_width, fitted_height):
        # The grid was measured before this fit.  Nearest-neighbour reduction
        # is therefore a deliberate logical-pixel selection, not continuous
        # illustration resizing.  The detected and fitted sizes stay in the
        # audit so the reduction is never hidden.
        subject = subject.resize(
            (fitted_width, fitted_height),
            Image.Resampling.NEAREST,
        )
        normalization_mode += "_fit_to_contract"
    subject = clean_transparency(subject)
    return NormalizedSubject(
        image=subject,
        source_path=source_path,
        source_analysis=analysis,
        logical_size=subject.size,
        detected_logical_size=detected_logical_size,
        logical_fit_scale=fit_scale,
        normalization_mode=normalization_mode,
    )


def _measure_periodic_pixel_grid(image: Image.Image) -> dict | None:
    """Second, independently-audited grid detector for sparse pixel art.

    The general analyzer intentionally requires abundant edges.  Large sprites
    with broad color clusters can have too few edges for its spacing-hint path,
    despite a strong shared phase.  This detector scans both axes directly and
    accepts only mutually consistent periods with meaningful phase energy.
    """
    periods: list[float] = []
    scores: list[float] = []
    for axis in (0, 1):
        signal = _collect_edge_signal(image, axis)
        candidates = [
            (_period_phase_score(signal, step / 20.0), step / 20.0)
            for step in range(80, 641)  # 4.00 .. 32.00 physical px
        ]
        score, period = max(candidates)
        periods.append(period)
        scores.append(score)
    average_score = sum(scores) * 0.5
    period_ratio = max(periods) / min(periods)
    if min(scores) < 0.25 or average_score < 0.32 or period_ratio > 1.15:
        return None
    logical_width = max(1, round(image.width / periods[0]))
    logical_height = max(1, round(image.height / periods[1]))
    if not (8 <= logical_width <= 160 and 8 <= logical_height <= 160):
        return None
    return {
        "detection_mode": "periodic_phase_fallback",
        "grid_cell_width": round(periods[0], 3),
        "grid_cell_height": round(periods[1], 3),
        "grid_cell_size": max(1, round(sum(periods) * 0.5)),
        "confidence": round(average_score, 3),
        "subject_grid_width": logical_width,
        "subject_grid_height": logical_height,
        "fallback_axis_scores": [round(score, 3) for score in scores],
        "fallback_period_ratio": round(period_ratio, 3),
    }


def place_bottom_center(
    subject: Image.Image,
    *,
    target: tuple[int, int] = (32, 62),
) -> tuple[Image.Image, tuple[int, int]]:
    """Register a building by its bbox bottom-centre on a 64px canvas."""
    target_x, target_bottom = target
    paste_x = round(target_x - subject.width * 0.5)
    paste_y = target_bottom - subject.height + 1
    return place_at(subject, (paste_x, paste_y)), (paste_x, paste_y)


def place_bbox_fraction_at_pivot(
    subject: Image.Image,
    *,
    source_fraction: tuple[float, float],
    target_pivot: tuple[int, int],
) -> tuple[Image.Image, tuple[int, int], tuple[int, int]]:
    """Register an animation frame to one declared output pivot.

    ``source_fraction`` is measured inside the cropped logical subject and is
    intentionally data, not a frame-specific heuristic hidden in scene code.
    """
    fraction_x, fraction_y = source_fraction
    source_anchor = (
        round((subject.width - 1) * fraction_x),
        round((subject.height - 1) * fraction_y),
    )
    paste_origin = (
        target_pivot[0] - source_anchor[0],
        target_pivot[1] - source_anchor[1],
    )
    return place_at(subject, paste_origin), paste_origin, source_anchor


def place_at(subject: Image.Image, origin: tuple[int, int]) -> Image.Image:
    paste_x, paste_y = origin
    if (
        paste_x < 0
        or paste_y < 0
        or paste_x + subject.width > CANVAS_SIDE
        or paste_y + subject.height > CANVAS_SIDE
    ):
        raise RuntimeError(
            f"Registered subject {subject.size} at {origin} escapes the "
            f"{CANVAS_SIDE}x{CANVAS_SIDE} source canvas"
        )
    canvas = Image.new("RGBA", (CANVAS_SIDE, CANVAS_SIDE), TRANSPARENT)
    canvas.alpha_composite(subject, origin)
    return clean_transparency(canvas)


def build_shared_palette(
    images: Iterable[Image.Image],
    *,
    max_colors: int = MAX_VISIBLE_COLORS,
) -> tuple[tuple[int, int, int], ...]:
    """Build one deterministic palette shared by every frame in a family."""
    visible_pixels: list[tuple[int, int, int]] = []
    for image in images:
        visible_pixels.extend(
            (red, green, blue)
            for red, green, blue, alpha in image.convert("RGBA").getdata()
            if alpha > 0
        )
    if not visible_pixels:
        raise RuntimeError("Cannot build a palette from empty images")

    sample = Image.new("RGB", (len(visible_pixels), 1))
    sample.putdata(visible_pixels)
    quantized = sample.quantize(
        colors=max_colors,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    )
    raw_palette = quantized.getpalette()
    used_indices = sorted(set(quantized.getdata()))
    palette = tuple(
        tuple(raw_palette[index * 3 : index * 3 + 3])
        for index in used_indices
    )
    if len(palette) > max_colors:
        raise RuntimeError(f"Palette unexpectedly contains {len(palette)} colors")
    return palette


def apply_palette(
    image: Image.Image,
    palette: Sequence[tuple[int, int, int]],
) -> Image.Image:
    rgba = image.convert("RGBA")
    result = Image.new("RGBA", rgba.size, TRANSPARENT)
    source = rgba.load()
    target = result.load()
    cache: dict[tuple[int, int, int], tuple[int, int, int]] = {}
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = source[x, y]
            if alpha == 0:
                continue
            rgb = (red, green, blue)
            chosen = cache.get(rgb)
            if chosen is None:
                chosen = min(
                    palette,
                    key=lambda color: (
                        (red - color[0]) ** 2
                        + (green - color[1]) ** 2
                        + (blue - color[2]) ** 2
                    ),
                )
                cache[rgb] = chosen
            target[x, y] = (*chosen, 255)
    return clean_transparency(result)


def alpha_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.convert("RGBA").getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Audited image is empty")
    return bbox


def foot_anchor(image: Image.Image) -> tuple[float, float]:
    left, _top, right, bottom = alpha_bbox(image)
    return ((left + right - 1) * 0.5, float(bottom - 1))


def max_visible_radius(
    image: Image.Image,
    pivot: tuple[int, int],
) -> float:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    radii = [
        math.hypot((x + 0.5) - pivot[0], (y + 0.5) - pivot[1])
        for y in range(rgba.height)
        for x in range(rgba.width)
        if pixels[x, y][3] > 0
    ]
    if not radii:
        raise RuntimeError("Cannot measure radius of an empty image")
    return max(radii)


def audit_image(
    image: Image.Image,
    *,
    label: str,
    path: str,
    max_subject_size: tuple[int, int] = (64, 64),
) -> dict:
    rgba = image.convert("RGBA")
    bbox = alpha_bbox(rgba)
    subject_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])
    alpha_values = set(rgba.getchannel("A").getdata())
    visible_colors = {
        (red, green, blue)
        for red, green, blue, alpha in rgba.getdata()
        if alpha > 0
    }
    transparent_rgb_clean = all(
        alpha > 0 or (red, green, blue) == (0, 0, 0)
        for red, green, blue, alpha in rgba.getdata()
    )
    world_bounds = [
        round((bbox[0] - CANVAS_SIDE * 0.5) * WORLD_SCALE, 3),
        round((bbox[1] - CANVAS_SIDE * 0.5) * WORLD_SCALE, 3),
        round((bbox[2] - CANVAS_SIDE * 0.5) * WORLD_SCALE, 3),
        round((bbox[3] - CANVAS_SIDE * 0.5) * WORLD_SCALE, 3),
    ]
    checks = {
        "canvas_64x64": rgba.size == (CANVAS_SIDE, CANVAS_SIDE),
        "binary_alpha": alpha_values.issubset({0, 255}),
        "transparent_rgb_clean": transparent_rgb_clean,
        "visible_colors_at_most_64": len(visible_colors) <= MAX_VISIBLE_COLORS,
        "subject_within_declared_limit": (
            subject_size[0] <= max_subject_size[0]
            and subject_size[1] <= max_subject_size[1]
        ),
        "world_bounds_within_32x32": (
            world_bounds[0] >= -16.0
            and world_bounds[1] >= -16.0
            and world_bounds[2] <= 16.0
            and world_bounds[3] <= 16.0
        ),
    }
    return {
        "label": label,
        "path": path,
        "canvas_size": list(rgba.size),
        "subject_bbox_exclusive": list(bbox),
        "subject_size": list(subject_size),
        "visible_color_count": len(visible_colors),
        "alpha_values": sorted(alpha_values),
        "world_bounds_at_scale_0_5": world_bounds,
        "checks": checks,
        "passed": all(checks.values()),
    }


def source_audit(subject: NormalizedSubject) -> dict:
    return {
        "path": portable_path(subject.source_path),
        "normalization_mode": subject.normalization_mode,
        "detected_logical_subject_size": list(subject.detected_logical_size),
        "logical_subject_size": list(subject.logical_size),
        "logical_fit_scale": round(subject.logical_fit_scale, 6),
        "grid_analysis": subject.source_analysis,
    }


def portable_path(path: Path) -> str:
    """Prefer stable repo-relative audit paths, retaining external temp paths."""
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return resolved.as_posix()


def validation_failures(outputs: Sequence[dict]) -> list[str]:
    failures: list[str] = []
    for output in outputs:
        for check_name, passed in output["checks"].items():
            if not passed:
                failures.append(f"{output['label']}: {check_name}")
    return failures
