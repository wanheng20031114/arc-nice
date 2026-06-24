#!/usr/bin/env python3
"""Build generated Capoo variant sprites and effect frames."""

from __future__ import annotations

from collections import OrderedDict
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
CAPOO_SOURCE = ROOT / "dev_assets/source_images/capoo_variants_generated.png"
EFFECT_SOURCE = ROOT / "dev_assets/source_images/capoo_special_effects_generated.png"

TEXTURE_DIR = ROOT / "resources/texture"
ANIMATION_DIR = ROOT / "resources/animation"

CAPOO_COLUMNS = 12
CAPOO_ROWS = 3
CAPOO_FRAME_SIZE = 96
CAPOO_VISIBLE_SIZE = 78

EFFECT_COLUMNS = 6
EFFECT_ROWS = 2
EFFECT_FRAME_SIZE = 64

CAPOO_VARIANTS = OrderedDict(
	[
		("capoo_mage", 0),
		("capoo_sniper", 1),
		("capoo_smg", 2),
	]
)

CAPOO_ANIMATION_ROWS = OrderedDict(
	[
		("move", 0),
		("windup", 1),
		("attack", 2),
		("death", 3),
	]
)

EFFECTS = OrderedDict(
	[
		("capoo_mage_fireball", 0),
		("capoo_sniper_lock_reticle", 1),
	]
)


def _remove_checker_background(image: Image.Image) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	rgb = array[:, :, :3].astype(np.int16)
	min_channel = rgb.min(axis=2)
	max_channel = rgb.max(axis=2)
	bright_low_saturation = (min_channel >= 190) & ((max_channel - min_channel) <= 48)

	seeds = np.zeros(bright_low_saturation.shape, dtype=bool)
	seeds[0, :] = bright_low_saturation[0, :]
	seeds[-1, :] = bright_low_saturation[-1, :]
	seeds[:, 0] = bright_low_saturation[:, 0]
	seeds[:, -1] = bright_low_saturation[:, -1]
	background = ndimage.binary_dilation(
		seeds,
		structure=np.ones((9, 9), dtype=bool),
		mask=bright_low_saturation,
		iterations=-1,
	)
	array[background] = (0, 0, 0, 0)
	array[:, :, 3][~background] = 255
	return Image.fromarray(array)


def _crop_grid_cell(sheet: Image.Image, columns: int, rows: int, column: int, row: int) -> Image.Image:
	cell_width = sheet.width / float(columns)
	cell_height = sheet.height / float(rows)
	left = round(column * cell_width)
	top = round(row * cell_height)
	right = round((column + 1) * cell_width)
	bottom = round((row + 1) * cell_height)
	return sheet.crop((left, top, right, bottom))


def _fit_cell_to_frame(cell: Image.Image, frame_size: int, visible_size: int) -> Image.Image:
	bbox = cell.getchannel("A").getbbox()
	if bbox is None:
		return Image.new("RGBA", (frame_size, frame_size), (0, 0, 0, 0))
	subject = cell.crop(bbox)
	scale = min(visible_size / float(subject.width), visible_size / float(subject.height))
	output_size = (
		max(1, round(subject.width * scale)),
		max(1, round(subject.height * scale)),
	)
	resized = subject.resize(output_size, Image.Resampling.LANCZOS)
	frame = Image.new("RGBA", (frame_size, frame_size), (0, 0, 0, 0))
	frame.alpha_composite(
		resized,
		(
			round((frame_size - output_size[0]) / 2.0),
			round((frame_size - output_size[1]) / 2.0),
		),
	)
	return frame


def _extract_capoo_row_frames(source: Image.Image, source_row: int) -> list[Image.Image]:
	alpha = np.array(source.getchannel("A"), dtype=np.uint8) > 0
	top = round(source_row * source.height / float(CAPOO_ROWS))
	bottom = round((source_row + 1) * source.height / float(CAPOO_ROWS))
	row_alpha = alpha[top:bottom, :]

	labels, _count = ndimage.label(row_alpha, structure=np.ones((3, 3), dtype=bool))
	component_boxes: list[tuple[int, int, int, int, int]] = []
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		component = labels[slices] == label_index
		alpha_pixels = int(component.sum())
		if alpha_pixels < 3000:
			continue
		local_y, local_x = np.nonzero(component)
		left = int(local_x.min() + slices[1].start)
		right = int(local_x.max() + slices[1].start + 1)
		component_boxes.append(
			(
			left,
			int(local_y.min() + slices[0].start + top),
			right,
			int(local_y.max() + slices[0].start + top + 1),
			alpha_pixels,
			)
		)

	component_boxes.sort(key=lambda box: (box[0] + box[2]) * 0.5)
	if not component_boxes:
		return [
			_crop_grid_cell(source, CAPOO_COLUMNS, CAPOO_ROWS, column, source_row)
			for column in range(CAPOO_COLUMNS)
		]

	frames: list[Image.Image] = []
	padding = 8
	for box in component_boxes:
		left = max(0, box[0] - padding)
		top = max(0, box[1] - padding)
		right = min(source.width, box[2] + padding)
		bottom = min(source.height, box[3] + padding)
		frames.append(source.crop((left, top, right, bottom)))
	while len(frames) < CAPOO_COLUMNS:
		frames.append(frames[-1].copy())
	return frames[:CAPOO_COLUMNS]


def _resize_cell_to_frame(cell: Image.Image, frame_size: int) -> Image.Image:
	return cell.resize((frame_size, frame_size), Image.Resampling.LANCZOS)


def _build_capoo_sheet(source: Image.Image, source_row: int) -> Image.Image:
	sheet = Image.new("RGBA", (CAPOO_FRAME_SIZE * 4, CAPOO_FRAME_SIZE * 4), (0, 0, 0, 0))
	source_frames = _extract_capoo_row_frames(source, source_row)
	for source_column in range(CAPOO_COLUMNS):
		cell = source_frames[source_column]
		frame = _fit_cell_to_frame(cell, CAPOO_FRAME_SIZE, CAPOO_VISIBLE_SIZE)
		output_row = 0 if source_column < 4 else (1 if source_column < 8 else 3)
		output_column = source_column % 4
		sheet.alpha_composite(frame, (output_column * CAPOO_FRAME_SIZE, output_row * CAPOO_FRAME_SIZE))

	for output_column in range(4):
		attack_frame = sheet.crop(
			(
				output_column * CAPOO_FRAME_SIZE,
				CAPOO_FRAME_SIZE,
				(output_column + 1) * CAPOO_FRAME_SIZE,
				CAPOO_FRAME_SIZE * 2,
			)
		)
		sheet.alpha_composite(attack_frame, (output_column * CAPOO_FRAME_SIZE, CAPOO_FRAME_SIZE * 2))
	return sheet


def _build_effect_sheet(source: Image.Image, source_row: int) -> Image.Image:
	sheet = Image.new("RGBA", (EFFECT_FRAME_SIZE * EFFECT_COLUMNS, EFFECT_FRAME_SIZE), (0, 0, 0, 0))
	for column in range(EFFECT_COLUMNS):
		cell = _crop_grid_cell(source, EFFECT_COLUMNS, EFFECT_ROWS, column, source_row)
		frame = _resize_cell_to_frame(cell, EFFECT_FRAME_SIZE)
		sheet.alpha_composite(frame, (column * EFFECT_FRAME_SIZE, 0))
	return sheet


def _write_capoo_frames(name: str) -> None:
	texture_path = f"res://resources/texture/{name}.png"
	lines = [
		"[gd_resource type=\"SpriteFrames\" format=3]",
		"",
		f"[ext_resource type=\"Texture2D\" path=\"{texture_path}\" id=\"1_texture\"]",
		"",
	]

	for animation_name, row in CAPOO_ANIMATION_ROWS.items():
		for column in range(4):
			lines.extend(
				[
					f"[sub_resource type=\"AtlasTexture\" id=\"AtlasTexture_{animation_name}_{column}\"]",
					"atlas = ExtResource(\"1_texture\")",
					f"region = Rect2({column * CAPOO_FRAME_SIZE}, {row * CAPOO_FRAME_SIZE}, {CAPOO_FRAME_SIZE}, {CAPOO_FRAME_SIZE})",
					"",
				]
			)

	animation_speeds = {
		"move": 6.0,
		"windup": 4.0,
		"attack": 10.0,
		"death": 7.0,
	}
	entries: list[str] = []
	for animation_name in CAPOO_ANIMATION_ROWS:
		frame_entries: list[str] = []
		for column in range(4):
			frame_entries.append(
				"{\n\"duration\": 1.0,\n"
				f"\"texture\": SubResource(\"AtlasTexture_{animation_name}_{column}\")\n}}"
			)
		entries.append(
			"{\n"
			f"\"frames\": [{', '.join(frame_entries)}],\n"
			f"\"loop\": {str(animation_name != 'death').lower()},\n"
			f"\"name\": &\"{animation_name}\",\n"
			f"\"speed\": {animation_speeds[animation_name]:.1f}\n"
			"}"
		)

	lines.append("[resource]")
	lines.append(f"animations = [{', '.join(entries)}]")
	lines.append("")
	(ANIMATION_DIR / f"{name}.tres").write_text("\n".join(lines), encoding="utf-8")


def _write_effect_frames(name: str) -> None:
	texture_path = f"res://resources/texture/{name}.png"
	animation_name = "fly" if name == "capoo_mage_fireball" else "lock"
	speed = 12.0 if name == "capoo_mage_fireball" else 6.0
	lines = [
		"[gd_resource type=\"SpriteFrames\" format=3]",
		"",
		f"[ext_resource type=\"Texture2D\" path=\"{texture_path}\" id=\"1_texture\"]",
		"",
	]
	for column in range(EFFECT_COLUMNS):
		lines.extend(
			[
				f"[sub_resource type=\"AtlasTexture\" id=\"AtlasTexture_{animation_name}_{column}\"]",
				"atlas = ExtResource(\"1_texture\")",
				f"region = Rect2({column * EFFECT_FRAME_SIZE}, 0, {EFFECT_FRAME_SIZE}, {EFFECT_FRAME_SIZE})",
				"",
			]
		)
	frame_entries = [
		"{\n\"duration\": 1.0,\n"
		f"\"texture\": SubResource(\"AtlasTexture_{animation_name}_{column}\")\n}}"
		for column in range(EFFECT_COLUMNS)
	]
	lines.append("[resource]")
	lines.append(
		"animations = [{\n"
		f"\"frames\": [{', '.join(frame_entries)}],\n"
		"\"loop\": true,\n"
		f"\"name\": &\"{animation_name}\",\n"
		f"\"speed\": {speed:.1f}\n"
		"}]"
	)
	lines.append("")
	(ANIMATION_DIR / f"{name}.tres").write_text("\n".join(lines), encoding="utf-8")


def _save_alpha_debug(name: str, image: Image.Image) -> None:
	debug_dir = ROOT / "tmp/capoo_variant_assets"
	debug_dir.mkdir(parents=True, exist_ok=True)
	image.save(debug_dir / f"{name}.png")


def main() -> None:
	if not CAPOO_SOURCE.is_file():
		raise FileNotFoundError(CAPOO_SOURCE)
	if not EFFECT_SOURCE.is_file():
		raise FileNotFoundError(EFFECT_SOURCE)

	TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
	ANIMATION_DIR.mkdir(parents=True, exist_ok=True)

	capoo_source = _remove_checker_background(Image.open(CAPOO_SOURCE))
	effect_source = _remove_checker_background(Image.open(EFFECT_SOURCE))
	_save_alpha_debug("capoo_variants_alpha", capoo_source)
	_save_alpha_debug("capoo_special_effects_alpha", effect_source)

	for name, row in CAPOO_VARIANTS.items():
		sheet = _build_capoo_sheet(capoo_source, row)
		sheet.save(TEXTURE_DIR / f"{name}.png")
		_write_capoo_frames(name)
		print(f"{name}: {sheet.width}x{sheet.height}, bbox={sheet.getchannel('A').getbbox()}")

	for name, row in EFFECTS.items():
		sheet = _build_effect_sheet(effect_source, row)
		sheet.save(TEXTURE_DIR / f"{name}.png")
		_write_effect_frames(name)
		print(f"{name}: {sheet.width}x{sheet.height}, bbox={sheet.getchannel('A').getbbox()}")


if __name__ == "__main__":
	main()
