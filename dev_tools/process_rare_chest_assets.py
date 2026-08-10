#!/usr/bin/env python3
"""Build the user-approved high-resolution rare-chest tableau.

The approved ImageGen edit is intentionally kept at its native resolution for
the static route UI.  This script performs no resize, palette reduction, or
resampling.  It only verifies the approved source hash, hardens transparency,
clears hidden RGB, removes residual chroma-key pixels, and writes the Godot
production PNG deterministically.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = (
    PROJECT_ROOT
    / "dev_assets/source_images/rogue_rare_chest/"
    "rare_chest_tableau_alpha_connected_v2_xiaocong.png"
)
PRODUCTION_PATH = (
    PROJECT_ROOT
    / "resources/texture/rogue_route/prepare_ahead/rare_chest_tableau.png"
)
APPROVED_SOURCE_SHA256 = (
    "090d273607664d855f2fd86a233a411e37bad2ca77d274296419415f859ad009"
)
APPROVED_SIZE = (1097, 1434)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _clean_hard_alpha(image: Image.Image) -> Image.Image:
    """Normalize the approved chroma-key result without resampling its pixels."""

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


def _audit(image: Image.Image) -> dict[str, object]:
    rgba = image.convert("RGBA")
    pixels = list(rgba.getdata())
    alpha_values = sorted({alpha for _, _, _, alpha in pixels})
    transparent_rgb_bad = sum(
        1
        for red, green, blue, alpha in pixels
        if alpha == 0 and (red != 0 or green != 0 or blue != 0)
    )
    partial_alpha_pixels = sum(
        1 for _, _, _, alpha in pixels if 0 < alpha < 255
    )
    visible_rgb_count = len(
        {
            (red, green, blue)
            for red, green, blue, alpha in pixels
            if alpha == 255
        }
    )
    if rgba.size != APPROVED_SIZE:
        raise ValueError(
            f"approved rare-chest size changed: {rgba.size} != {APPROVED_SIZE}"
        )
    if alpha_values != [0, 255]:
        raise ValueError(f"expected hard alpha, got {alpha_values}")
    if partial_alpha_pixels != 0:
        raise ValueError(f"partial alpha pixels remain: {partial_alpha_pixels}")
    if transparent_rgb_bad != 0:
        raise ValueError(
            f"transparent pixels with non-zero RGB: {transparent_rgb_bad}"
        )
    return {
        "size": list(rgba.size),
        "mode": rgba.mode,
        "subject_bbox": list(rgba.getchannel("A").getbbox() or ()),
        "alpha_values": alpha_values,
        "partial_alpha_pixels": partial_alpha_pixels,
        "transparent_rgb_bad": transparent_rgb_bad,
        "visible_rgb_count": visible_rgb_count,
        "corners": [
            list(rgba.getpixel((0, 0))),
            list(rgba.getpixel((rgba.width - 1, 0))),
            list(rgba.getpixel((0, rgba.height - 1))),
            list(rgba.getpixel((rgba.width - 1, rgba.height - 1))),
        ],
    }


def main() -> None:
    source_sha256 = _sha256(SOURCE_PATH)
    if source_sha256 != APPROVED_SOURCE_SHA256:
        raise ValueError(
            "rare-chest approved source SHA-256 changed: "
            f"{source_sha256} != {APPROVED_SOURCE_SHA256}"
        )

    production = _clean_hard_alpha(Image.open(SOURCE_PATH))
    production_audit = _audit(production)
    PRODUCTION_PATH.parent.mkdir(parents=True, exist_ok=True)
    production.save(PRODUCTION_PATH, format="PNG", optimize=False)

    result = {
        "approved_source": {
            "path": str(SOURCE_PATH.relative_to(PROJECT_ROOT)).replace("\\", "/"),
            "sha256": source_sha256,
        },
        "production": {
            "path": str(PRODUCTION_PATH.relative_to(PROJECT_ROOT)).replace(
                "\\", "/"
            ),
            "sha256": _sha256(PRODUCTION_PATH),
            **production_audit,
        },
        "resampling": "none",
        "palette_reduction": "none",
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
