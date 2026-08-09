#!/usr/bin/env python3
"""Deterministically build the Rogue supply-node production textures.

The ImageGen sources are intentionally retained under dev_assets.  Chroma-key
removal is performed before this script for the two transparent sources.  The
production assets intentionally use a small logical canvas and nearest-neighbour
upscale so the result stays chunky instead of drifting back toward dense UI art.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "dev_assets/source_images/rogue_supply"
SUPPLY_TEXTURE_DIR = PROJECT_ROOT / "resources/texture/rogue_route/supply"
COLLECTIBLE_TEXTURE_DIR = PROJECT_ROOT / "resources/texture/collectibles"

PANEL_LOGICAL_SIZE = (130, 37)
PANEL_SIZE = (520, 148)
TABLEAU_LOGICAL_SIZE = (122, 159)
TABLEAU_SIZE = (366, 478)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _hard_alpha(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    cleaned: list[tuple[int, int, int, int]] = []
    for red, green, blue, alpha in rgba.getdata():
        is_key_fringe = red > green + 24 and blue > green + 24
        if alpha < 127 or is_key_fringe:
            cleaned.append((0, 0, 0, 0))
        else:
            cleaned.append((red, green, blue, 255))
    rgba.putdata(cleaned)
    return rgba


def _quantize_rgb(image: Image.Image, color_count: int) -> Image.Image:
    return image.convert("RGB").quantize(
        colors=color_count,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    ).convert("RGB")


def _quantize_rgba(image: Image.Image, color_count: int) -> Image.Image:
    source = _hard_alpha(image)
    alpha = source.getchannel("A")
    quantized = _quantize_rgb(source, color_count).convert("RGBA")
    quantized.putalpha(alpha)
    return _hard_alpha(quantized)


def _fit_alpha_subject(
    image: Image.Image,
    canvas_size: tuple[int, int],
    padding: int,
) -> Image.Image:
    source = _hard_alpha(image)
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("transparent source has no subject")
    subject = source.crop(bbox)
    available_width = canvas_size[0] - padding * 2
    available_height = canvas_size[1] - padding * 2
    fit_scale = min(
        available_width / subject.width,
        available_height / subject.height,
    )
    fitted_size = (
        max(1, round(subject.width * fit_scale)),
        max(1, round(subject.height * fit_scale)),
    )
    subject = subject.resize(fitted_size, Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    canvas.alpha_composite(
        subject,
        (
            (canvas_size[0] - subject.width) // 2,
            (canvas_size[1] - subject.height) // 2,
        ),
    )
    return canvas


def _build_tableau() -> Path:
    source_path = SOURCE_DIR / "supply_tableau_approved_alpha.png"
    source = _hard_alpha(Image.open(source_path))
    if source.size != (1098, 1433):
        raise ValueError(f"unexpected tableau source size: {source.size}")
    logical = _fit_alpha_subject(source, TABLEAU_LOGICAL_SIZE, padding=3)
    logical = _quantize_rgba(logical, color_count=20)
    scaled = logical.resize((366, 477), Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", TABLEAU_SIZE, (0, 0, 0, 0))
    canvas.alpha_composite(scaled, (0, 0))

    output_path = SUPPLY_TEXTURE_DIR / "supply_tableau.png"
    canvas.save(output_path, optimize=False)
    return output_path


def _build_panel(variant: str) -> Path:
    source_path = SOURCE_DIR / f"supply_choice_panel_{variant}_blocky_imagegen.png"
    source = Image.open(source_path).convert("RGB")
    logical = source.resize(PANEL_LOGICAL_SIZE, Image.Resampling.NEAREST)
    logical = _quantize_rgb(logical, color_count=8)
    canvas = logical.resize(PANEL_SIZE, Image.Resampling.NEAREST)

    output_path = SUPPLY_TEXTURE_DIR / f"supply_choice_panel_{variant}.png"
    canvas.save(output_path, optimize=False)
    return output_path


def _build_envelope() -> Path:
    source_path = SOURCE_DIR / "flying_envelope_approved_32.png"
    source = _hard_alpha(Image.open(source_path))
    if source.size != (32, 32):
        raise ValueError(f"unexpected envelope production size: {source.size}")
    output_path = COLLECTIBLE_TEXTURE_DIR / "flying_envelope.png"
    source.save(output_path, optimize=False)
    return output_path


def _write_manifest(outputs: list[Path]) -> None:
    inputs = sorted(SOURCE_DIR.glob("*.png"))
    payload = {
        "pipeline": "built-in ImageGen -> chroma-key removal where needed -> low-resolution palette reduction -> nearest 4x/3x upscale",
        "grid_review": (
            "The generated sources were inspected manually after pixel_grid_analyzer. "
            "The user explicitly requested lower pixel density without voxelizing the "
            "scene. The user then explicitly selected the final ruined supply-cache "
            "tableau, which uses a 122x159 logical canvas, while the "
            "cards use 130x37. The user explicitly approved the first flying-envelope "
            "source; it uses the project crop tool directly at 32x32 after manual review."
        ),
        "inputs": {
            str(path.relative_to(PROJECT_ROOT)).replace("\\", "/"): _sha256(path)
            for path in inputs
        },
        "outputs": {
            str(path.relative_to(PROJECT_ROOT)).replace("\\", "/"): {
                "sha256": _sha256(path),
                "size": list(Image.open(path).size),
            }
            for path in outputs
        },
    }
    (SOURCE_DIR / "asset_manifest.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    SUPPLY_TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    COLLECTIBLE_TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    outputs = [_build_tableau()]
    outputs.extend(_build_panel(variant) for variant in ("a", "b", "c"))
    outputs.append(_build_envelope())
    _write_manifest(outputs)


if __name__ == "__main__":
    main()
