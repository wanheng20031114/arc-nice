#!/usr/bin/env python3
"""Build deterministic underground-shop interaction UI textures.

The native-transparent ImageGen sources intentionally live under ``dev_assets``.
This script normalizes their visual pixel grid with PerfectPixel, preserves the
source Alpha, applies a restrained palette, and derives the
four product-card states from the project's existing inventory-slot language.
Backgrounds and character art stay outside this asset pipeline.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PERFECT_PIXEL_SRC = PROJECT_ROOT / "参考用" / "perfectPixel" / "src"
if str(PERFECT_PIXEL_SRC) not in sys.path:
	sys.path.insert(0, str(PERFECT_PIXEL_SRC))
if str(PROJECT_ROOT / "dev_tools") not in sys.path:
	sys.path.insert(0, str(PROJECT_ROOT / "dev_tools"))

from perfect_pixel.perfect_pixel_noCV2 import get_perfect_pixel  # noqa: E402


SOURCE_DIR = PROJECT_ROOT / "dev_assets" / "source_images" / "rogue_shop" / "underground_shop"
IMAGEGEN_SOURCE_FILES = (
	"panel_imagegen_transparent_v2.png",
	"title_plaque_imagegen_transparent_v2.png",
	"button_states_imagegen_transparent_v2.png",
)
INVENTORY_SLOT_EMPTY = PROJECT_ROOT / "resources" / "texture" / "rogue_route" / "inventory" / "inventory_slot_empty_ref_v3.png"
INVENTORY_SLOT_SELECTED = PROJECT_ROOT / "resources" / "texture" / "rogue_route" / "inventory" / "inventory_slot_selected_ref_v3.png"
RUNTIME_ROOT = PROJECT_ROOT / "resources" / "texture" / "rogue_shop"
UI_DIR = RUNTIME_ROOT / "ui"
BUILD_MANIFEST = (
	PROJECT_ROOT / "dev_tools/output/underground_shop/asset_build_manifest.json"
)

def _perfect_pixel(source: Path, grid_size: tuple[int, int] | None) -> Image.Image:
	with Image.open(source) as loaded:
		rgba = loaded.convert("RGBA")
	if rgba.getchannel("A").getextrema()[0] == 255:
		raise RuntimeError(f"ImageGen source must have a native transparent background: {source}")
	rgb = np.asarray(rgba.convert("RGB"), dtype=np.uint8)
	width, height, result = get_perfect_pixel(
		rgb,
		sample_method="center",
		grid_size=grid_size,
		refine_intensity=0.25,
		fix_square=False,
		debug=False,
	)
	if width is None or height is None:
		raise RuntimeError(f"PerfectPixel failed to resolve a grid for {source}")
	logical = Image.fromarray(result.astype(np.uint8), mode="RGB").convert("RGBA")
	alpha = rgba.getchannel("A").resize(logical.size, Image.Resampling.NEAREST)
	logical.putalpha(alpha)
	array = np.asarray(logical, dtype=np.uint8).copy()
	array[array[:, :, 3] == 0] = (0, 0, 0, 0)
	return Image.fromarray(array, mode="RGBA")


def _tight_crop(image: Image.Image) -> Image.Image:
	alpha = image.convert("RGBA").getchannel("A")
	bbox = alpha.getbbox()
	if bbox is None:
		raise RuntimeError("Generated component has no visible pixels")
	return image.crop(bbox)


def _fit_canvas(
	image: Image.Image,
	target_size: tuple[int, int],
	*,
	align_y: str = "center",
) -> Image.Image:
	target_width, target_height = target_size
	mode = "RGBA" if image.mode == "RGBA" else "RGB"
	fill = (0, 0, 0, 0) if mode == "RGBA" else (0, 0, 0)
	working = image.convert(mode)

	if working.width > target_width:
		left = (working.width - target_width) // 2
		working = working.crop((left, 0, left + target_width, working.height))
	if working.height > target_height:
		if align_y == "top":
			top = 0
		elif align_y == "bottom":
			top = working.height - target_height
		else:
			top = (working.height - target_height) // 2
		working = working.crop((0, top, working.width, top + target_height))

	canvas = Image.new(mode, target_size, fill)
	left = (target_width - working.width) // 2
	if align_y == "top":
		top = 0
	elif align_y == "bottom":
		top = target_height - working.height
	else:
		top = (target_height - working.height) // 2
	canvas.paste(working, (left, top), working if mode == "RGBA" else None)
	return canvas


def _quantize(image: Image.Image, color_count: int) -> Image.Image:
	if image.mode == "RGBA":
		alpha = image.getchannel("A")
		rgb = image.convert("RGB").quantize(
			colors=color_count,
			method=Image.Quantize.MEDIANCUT,
			dither=Image.Dither.NONE,
		).convert("RGB")
		result = rgb.convert("RGBA")
		result.putalpha(alpha)
		array = np.asarray(result, dtype=np.uint8).copy()
		array[array[:, :, 3] == 0, :3] = 0
		return Image.fromarray(array, mode="RGBA")
	return image.convert("RGB").quantize(
		colors=color_count,
		method=Image.Quantize.MEDIANCUT,
		dither=Image.Dither.NONE,
	).convert("RGB")


def _darken_region(
	image: Image.Image,
	box: tuple[int, int, int, int],
	factor: float,
) -> Image.Image:
	array = np.asarray(image.convert("RGBA"), dtype=np.uint8).copy()
	left, top, right, bottom = box
	region = array[top:bottom, left:right]
	visible = region[:, :, 3] > 0
	darkened = np.clip(
		region[:, :, :3].astype(np.float32) * factor,
		0.0,
		255.0,
	).astype(np.uint8)
	region[:, :, :3][visible] = darkened[visible]
	array[top:bottom, left:right] = region
	array[array[:, :, 3] == 0, :3] = 0
	return Image.fromarray(array, mode="RGBA")


def _rgba_bbox(image: Image.Image) -> tuple[int, int, int, int] | None:
	return image.convert("RGBA").getchannel("A").getbbox()


def _sha256(path: Path) -> str:
	return hashlib.sha256(path.read_bytes()).hexdigest()


def _save(image: Image.Image, output: Path) -> dict[str, object]:
	output.parent.mkdir(parents=True, exist_ok=True)
	image.save(output, format="PNG", optimize=False)
	relative = output.relative_to(PROJECT_ROOT).as_posix()
	return {
		"path": relative,
		"size": [image.width, image.height],
		"mode": image.mode,
		"visible_bbox": list(_rgba_bbox(image)) if image.mode == "RGBA" else None,
		"sha256": _sha256(output),
	}


def _build_panel() -> Image.Image:
	logical = _perfect_pixel(SOURCE_DIR / IMAGEGEN_SOURCE_FILES[0], (154, 154))
	logical = _tight_crop(logical)
	if logical.width > 136 or logical.height > 136:
		raise RuntimeError(f"Panel subject exceeds its logical canvas: {logical.size}")
	panel = _quantize(_fit_canvas(logical, (136, 136)), 32)
	return _darken_region(panel, (16, 16, 120, 120), 0.52)


def _build_title_plaque() -> Image.Image:
	logical = _perfect_pixel(SOURCE_DIR / IMAGEGEN_SOURCE_FILES[1], (150, 61))
	logical = _tight_crop(logical)
	if logical.width > 136 or logical.height > 32:
		raise RuntimeError(f"Title plaque exceeds its logical canvas: {logical.size}")
	return _quantize(_fit_canvas(logical, (136, 32)), 32)


def _button_row_bounds() -> list[tuple[int, int, int, int]]:
	with Image.open(SOURCE_DIR / IMAGEGEN_SOURCE_FILES[2]) as loaded:
		rgba = np.asarray(loaded.convert("RGBA"), dtype=np.uint8)
	if rgba[:, :, 3].min() == 255:
		raise RuntimeError("Button sheet must have a native transparent background")
	visible = rgba[:, :, 3] > 0
	row_has_alpha = np.any(visible, axis=1)
	intervals: list[tuple[int, int]] = []
	start: int | None = None
	for row_index, occupied in enumerate(row_has_alpha):
		if occupied and start is None:
			start = row_index
		elif not occupied and start is not None:
			intervals.append((start, row_index))
			start = None
	if start is not None:
		intervals.append((start, visible.shape[0]))
	if len(intervals) != 4:
		raise RuntimeError(f"Expected four button rows, got {intervals}")

	bounds: list[tuple[int, int, int, int]] = []
	for top, bottom in intervals:
		rows = visible[top:bottom, :]
		columns = np.any(rows, axis=0)
		x_indices = np.flatnonzero(columns)
		bounds.append((int(x_indices[0]), top, int(x_indices[-1]) + 1, bottom))
	return bounds


def _build_buttons() -> dict[str, Image.Image]:
	state_names = ("normal", "hover", "pressed", "disabled")
	with Image.open(SOURCE_DIR / IMAGEGEN_SOURCE_FILES[2]) as loaded:
		sheet = loaded.convert("RGBA")
	outputs: dict[str, Image.Image] = {}
	for state_name, bounds in zip(state_names, _button_row_bounds(), strict=True):
		component = sheet.crop(bounds)
		rgb = np.asarray(component.convert("RGB"), dtype=np.uint8)
		_width, _height, sampled = get_perfect_pixel(
			rgb,
			sample_method="center",
			grid_size=(100, 27),
			refine_intensity=0.25,
			fix_square=False,
			debug=False,
		)
		logical = Image.fromarray(sampled.astype(np.uint8), mode="RGB").convert("RGBA")
		alpha = component.getchannel("A").resize(logical.size, Image.Resampling.NEAREST)
		logical.putalpha(alpha)
		logical = _tight_crop(logical)
		if logical.width > 104 or logical.height > 28:
			raise RuntimeError(f"Button {state_name} exceeds its logical canvas: {logical.size}")
		button = _quantize(_fit_canvas(logical, (104, 28)), 24)
		outputs[state_name] = _darken_region(button, (10, 8, 94, 20), 0.58)
	return outputs


def _draw_price_well(
	image: Image.Image,
	*,
	line_color: tuple[int, int, int, int],
	fill_color: tuple[int, int, int, int],
) -> Image.Image:
	array = np.asarray(image.convert("RGBA"), dtype=np.uint8).copy()
	array[78:80, 22:106] = line_color
	array[80:106, 20:108] = fill_color
	array[106:108, 22:106] = (7, 8, 9, 255)
	array[82:104, 20:22] = (8, 9, 10, 255)
	array[82:104, 106:108] = (28, 29, 28, 255)
	array[array[:, :, 3] == 0, :3] = 0
	return Image.fromarray(array, mode="RGBA")


def _desaturate_and_darken(image: Image.Image) -> Image.Image:
	array = np.asarray(image.convert("RGBA"), dtype=np.uint8).copy()
	rgb = array[:, :, :3].astype(np.float32)
	luminance = (
		rgb[:, :, 0] * 0.2126
		+ rgb[:, :, 1] * 0.7152
		+ rgb[:, :, 2] * 0.0722
	)
	muted = np.repeat(luminance[:, :, None], 3, axis=2) * 0.55
	array[:, :, :3] = np.clip(muted, 0.0, 255.0).astype(np.uint8)
	array[array[:, :, 3] == 0, :3] = 0
	return Image.fromarray(array, mode="RGBA")


def _harden_alpha(image: Image.Image) -> Image.Image:
	array = np.asarray(image.convert("RGBA"), dtype=np.uint8).copy()
	visible = array[:, :, 3] >= 128
	array[:, :, 3] = np.where(visible, 255, 0).astype(np.uint8)
	array[~visible, :3] = 0
	return Image.fromarray(array, mode="RGBA")


def _build_product_card_states() -> dict[str, Image.Image]:
	with Image.open(INVENTORY_SLOT_EMPTY) as loaded:
		normal_base = _harden_alpha(loaded)
	with Image.open(INVENTORY_SLOT_SELECTED) as loaded:
		selected_base = _harden_alpha(loaded)
	if normal_base.size != (128, 128) or selected_base.size != (128, 128):
		raise RuntimeError("Inventory slot references must remain 128×128")

	normal = _draw_price_well(
		normal_base,
		line_color=(64, 61, 51, 255),
		fill_color=(15, 17, 18, 255),
	)
	hover = _draw_price_well(
		selected_base,
		line_color=(119, 82, 25, 255),
		fill_color=(18, 18, 17, 255),
	)
	pressed = _darken_region(hover, (16, 16, 112, 112), 0.72)
	disabled = _desaturate_and_darken(normal)
	return {
		"normal": normal,
		"hover": hover,
		"pressed": pressed,
		"disabled": disabled,
	}


def main() -> int:
	outputs: dict[str, dict[str, object]] = {}
	outputs["panel_frame"] = _save(
		_build_panel(),
		UI_DIR / "shop_panel_frame_v1.png",
	)
	outputs["title_plaque"] = _save(
		_build_title_plaque(),
		UI_DIR / "shop_title_plaque_v1.png",
	)
	for state_name, image in _build_buttons().items():
		outputs[f"button_{state_name}"] = _save(
			image,
			UI_DIR / f"shop_button_{state_name}_v1.png",
		)
	for state_name, image in _build_product_card_states().items():
		outputs[f"product_card_{state_name}"] = _save(
			image,
			UI_DIR / f"shop_product_card_{state_name}_v2.png",
		)

	sources = {}
	for source_name in IMAGEGEN_SOURCE_FILES:
		source = SOURCE_DIR / source_name
		sources[source.name] = _sha256(source)
	for source in (INVENTORY_SLOT_EMPTY, INVENTORY_SLOT_SELECTED):
		sources[source.relative_to(PROJECT_ROOT).as_posix()] = _sha256(source)
	manifest = {
		"schema_version": 1,
		"generator": "dev_tools/process_underground_shop_assets.py",
		"perfect_pixel_implementation": "参考用/perfectPixel/src/perfect_pixel/perfect_pixel_noCV2.py",
		"sources": sources,
		"outputs": outputs,
	}
	BUILD_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
	BUILD_MANIFEST.write_text(
		json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
		encoding="utf-8",
	)
	print(json.dumps(manifest["outputs"], ensure_ascii=False, indent=2))
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
