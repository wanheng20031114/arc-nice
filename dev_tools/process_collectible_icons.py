#!/usr/bin/env python3
"""Build 32x32 collectible item icons from the generated icon sheet."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

from pixel_crop_tool import crop_to_square, normalize_transparency


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev_assets/source_images/collectible_icons_indie_sheet.png"
OUTPUT_DIR = ROOT / "resources/texture/collectibles"

ICON_NAMES = [
	"gold_wine_cup",
	"tianshi_stake",
	"ruby",
	"emerald",
	"topaz",
	"gray_gem",
	"amethyst",
	"power_ring",
	"life_ring",
	"speed_ring",
	"physical_ring",
	"magic_ring",
	"moon_amulet",
	"thunder_crystal",
	"frost_crystal",
	"life_crystal",
	"swift_crystal",
	"admin_doll",
]

GRID_COLUMNS = 6
GRID_ROWS = 3
OUTPUT_SIZE = 32


def _trim_alpha(image: Image.Image) -> Image.Image:
	alpha = image.getchannel("A")
	bbox = alpha.getbbox()
	if bbox == None:
		return Image.new("RGBA", (OUTPUT_SIZE, OUTPUT_SIZE), (0, 0, 0, 0))
	return image.crop(bbox)


def _fit_to_icon(image: Image.Image) -> Image.Image:
	normalized = normalize_transparency(image, alpha_threshold=4)
	cropped = crop_to_square(normalized, padding=8, align_to_grid=False)
	cropped = _trim_alpha(cropped)

	canvas_side = max(cropped.width, cropped.height)
	canvas = Image.new("RGBA", (canvas_side, canvas_side), (0, 0, 0, 0))
	canvas.paste(
		cropped,
		((canvas_side - cropped.width) // 2, (canvas_side - cropped.height) // 2),
		cropped,
	)
	return canvas.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.Resampling.NEAREST)


def _is_icon_empty(image: Image.Image) -> bool:
	alpha = np.array(image.getchannel("A"), dtype=np.uint8)
	return int(np.count_nonzero(alpha)) <= 0


def main() -> None:
	if not SOURCE.is_file():
		raise FileNotFoundError(f"Missing source sheet: {SOURCE}")

	OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
	sheet = Image.open(SOURCE).convert("RGBA")
	if sheet.getchannel("A").getextrema()[0] == 255:
		raise ValueError("Collectible icon sheet must have a native transparent background")
	cell_width = sheet.width / float(GRID_COLUMNS)
	cell_height = sheet.height / float(GRID_ROWS)

	for index, icon_name in enumerate(ICON_NAMES):
		column = index % GRID_COLUMNS
		row = index // GRID_COLUMNS
		left = round(column * cell_width)
		top = round(row * cell_height)
		right = round((column + 1) * cell_width)
		bottom = round((row + 1) * cell_height)
		cell = sheet.crop((left, top, right, bottom))
		icon = _fit_to_icon(cell)
		if _is_icon_empty(icon):
			raise ValueError(f"Processed icon is empty: {icon_name}")
		icon.save(OUTPUT_DIR / f"{icon_name}.png")

	print(f"Processed {len(ICON_NAMES)} collectible icons into {OUTPUT_DIR}")


if __name__ == "__main__":
	main()
