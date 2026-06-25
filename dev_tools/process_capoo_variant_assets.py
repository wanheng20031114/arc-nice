#!/usr/bin/env python3
"""Build Capoo variant sprites from chroma-keyed imagegen sources."""

from __future__ import annotations

from collections import OrderedDict
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
CAPOO_SOURCE = ROOT / "dev_assets/source_images/capoo_variants_generated_v2.png"
PROJECTILE_SOURCE = ROOT / "dev_assets/source_images/capoo_projectiles_generated_v2.png"
FIREBALL_IMPACT_SOURCE = ROOT / "dev_assets/source_images/capoo_mage_fireball_impact_generated.png"

TEXTURE_DIR = ROOT / "resources/texture"
ANIMATION_DIR = ROOT / "resources/animation"
DEBUG_DIR = ROOT / "tmp/capoo_variant_assets"

CAPOO_SOURCE_COLUMNS = 12
CAPOO_SOURCE_ROWS = 3
CAPOO_FRAME_SIZE = 96
CAPOO_VISIBLE_SIZE = 78
CAPOO_MAJOR_COMPONENT_PIXELS = 3000
CAPOO_COMPONENT_MIN_PIXELS = 45
CAPOO_FRAME_PADDING = 8

FIREBALL_FRAME_SIZE = 64
FIREBALL_VISIBLE_SIZE = 46
FIREBALL_FRAME_COUNT = 6
FIREBALL_IMPACT_VISIBLE_SIZE = 44
FIREBALL_SPRITE_FRAMES_UID = "uid://cemn3y2bgbhbs"
FIREBALL_TEXTURE_UID = "uid://df4rkbjjnc1lc"

SMG_BULLET_FRAME_WIDTH = 16
SMG_BULLET_FRAME_HEIGHT = 8
SMG_BULLET_FRAME_COUNT = 3

RETICLE_SIZE = 32

CAPOO_VARIANTS = OrderedDict(
	[
		("capoo_sniper", 1),
		("capoo_smg", 2),
	]
)

SPRITE_FRAME_UIDS = {
	"capoo_mage": "uid://bynglissk1f1v",
	"capoo_sniper": "uid://b0k8qc31gx3ei",
	"capoo_smg": "uid://bjqyhx872ip4x",
}

TEXTURE_UIDS = {
	"capoo_mage": "uid://vsdfb65jljbp",
	"capoo_sniper": "uid://cmwmkm7b0kdc7",
	"capoo_smg": "uid://c3anlhqnkov42",
}

CAPOO_ANIMATION_ROWS = OrderedDict(
	[
		("move", 0),
		("windup", 1),
		("attack", 2),
		("death", 3),
	]
)
CAPOO_ANIMATION_WRITE_ORDER = ("attack", "death", "move", "windup")


def _remove_chroma_background(image: Image.Image, key: str) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	rgb = array[:, :, :3].astype(np.int16)
	red = rgb[:, :, 0]
	green = rgb[:, :, 1]
	blue = rgb[:, :, 2]

	if key == "magenta":
		candidate = (
			(red >= 130)
			& (blue >= 130)
			& (green <= 125)
			& ((red - green) >= 55)
			& ((blue - green) >= 55)
		)
	elif key == "green":
		candidate = (
			(green >= 120)
			& ((green - red) >= 45)
			& ((green - blue) >= 45)
		)
	else:
		raise ValueError(f"Unsupported chroma key: {key}")

	seeds = np.zeros(candidate.shape, dtype=bool)
	seeds[0, :] = candidate[0, :]
	seeds[-1, :] = candidate[-1, :]
	seeds[:, 0] = candidate[:, 0]
	seeds[:, -1] = candidate[:, -1]
	background = ndimage.binary_propagation(
		seeds,
		structure=np.ones((5, 5), dtype=bool),
		mask=candidate,
	)

	array[background] = (0, 0, 0, 0)
	visible = ~background
	array[:, :, 3][visible] = 255
	array[:, :, :3][~visible] = 0
	_despill(array, key, visible)
	return Image.fromarray(array)


def _despill(array: np.ndarray, key: str, visible: np.ndarray) -> None:
	rgb = array[:, :, :3].astype(np.int16)
	red = rgb[:, :, 0]
	green = rgb[:, :, 1]
	blue = rgb[:, :, 2]

	if key == "green":
		fringe = visible & (green > red + 18) & (green > blue + 18)
		green_limit = np.maximum(red, blue) + 10
		array[:, :, 1][fringe] = np.minimum(green[fringe], green_limit[fringe]).astype(np.uint8)
	elif key == "magenta":
		fringe = visible & (red > green + 32) & (blue > green + 32) & (red > 120) & (blue > 120)
		limit = green + 90
		array[:, :, 0][fringe] = np.minimum(red[fringe], limit[fringe]).astype(np.uint8)
		array[:, :, 2][fringe] = np.minimum(blue[fringe], limit[fringe]).astype(np.uint8)


def _crop_grid_cell(sheet: Image.Image, columns: int, rows: int, column: int, row: int) -> Image.Image:
	cell_width = sheet.width / float(columns)
	cell_height = sheet.height / float(rows)
	left = round(column * cell_width)
	top = round(row * cell_height)
	right = round((column + 1) * cell_width)
	bottom = round((row + 1) * cell_height)
	return sheet.crop((left, top, right, bottom))


def _subject_bbox(image: Image.Image) -> tuple[int, int, int, int] | None:
	return image.convert("RGBA").getchannel("A").getbbox()


def _fit_subject_to_frame(
	cell: Image.Image,
	frame_size: tuple[int, int],
	visible_size: tuple[int, int],
	anchor: tuple[float, float] | None = None,
) -> Image.Image:
	bbox = _subject_bbox(cell)
	frame = Image.new("RGBA", frame_size, (0, 0, 0, 0))
	if bbox is None:
		return frame

	subject = cell.crop(bbox)
	scale = min(
		visible_size[0] / float(subject.width),
		visible_size[1] / float(subject.height),
		1.0,
	)
	output_size = (
		max(1, round(subject.width * scale)),
		max(1, round(subject.height * scale)),
	)
	resized = subject.resize(output_size, Image.Resampling.NEAREST)
	if anchor == None:
		paste_position = (
			round((frame_size[0] - output_size[0]) / 2.0),
			round((frame_size[1] - output_size[1]) / 2.0),
		)
	else:
		paste_position = (
			round(anchor[0] - output_size[0] / 2.0),
			round(anchor[1] - output_size[1] / 2.0),
		)
	frame.alpha_composite(resized, paste_position)
	return frame


def _extract_capoo_row_frames(source: Image.Image, source_row: int) -> list[Image.Image]:
	alpha = np.array(source.getchannel("A"), dtype=np.uint8) > 0
	top = round(source_row * source.height / float(CAPOO_SOURCE_ROWS))
	bottom = round((source_row + 1) * source.height / float(CAPOO_SOURCE_ROWS))
	row_alpha = alpha[top:bottom, :]

	labels, _count = ndimage.label(row_alpha, structure=np.ones((3, 3), dtype=bool))
	components: list[tuple[int, int, int, int, int]] = []
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		component = labels[slices] == label_index
		alpha_pixels = int(component.sum())
		if alpha_pixels < CAPOO_COMPONENT_MIN_PIXELS:
			continue
		local_y, local_x = np.nonzero(component)
		left = int(local_x.min() + slices[1].start)
		right = int(local_x.max() + slices[1].start + 1)
		components.append(
			(
				alpha_pixels,
				left,
				int(local_y.min() + slices[0].start + top),
				right,
				int(local_y.max() + slices[0].start + top + 1),
			)
		)

	major_components = [
		component
		for component in components
		if component[0] >= CAPOO_MAJOR_COMPONENT_PIXELS
	]
	major_components.sort(key=lambda box: (box[1] + box[3]) * 0.5)
	if not major_components:
		return [
			_crop_grid_cell(source, CAPOO_SOURCE_COLUMNS, CAPOO_SOURCE_ROWS, column, source_row)
			for column in range(CAPOO_SOURCE_COLUMNS)
		]

	centers = [(box[1] + box[3]) * 0.5 for box in major_components]
	boundaries = [0.0]
	for left_center, right_center in zip(centers, centers[1:]):
		boundaries.append((left_center + right_center) * 0.5)
	boundaries.append(float(source.width))

	grouped_boxes: list[list[tuple[int, int, int, int, int]]] = [
		[component] for component in major_components
	]
	for component in components:
		if component in major_components:
			continue
		center_x = (component[1] + component[3]) * 0.5
		for index in range(len(major_components)):
			if boundaries[index] <= center_x < boundaries[index + 1]:
				grouped_boxes[index].append(component)
				break

	frames: list[Image.Image] = []
	for group in grouped_boxes:
		left = max(0, min(box[1] for box in group) - CAPOO_FRAME_PADDING)
		top = max(0, min(box[2] for box in group) - CAPOO_FRAME_PADDING)
		right = min(source.width, max(box[3] for box in group) + CAPOO_FRAME_PADDING)
		bottom = min(source.height, max(box[4] for box in group) + CAPOO_FRAME_PADDING)
		frames.append(source.crop((left, top, right, bottom)))

	while len(frames) < CAPOO_SOURCE_COLUMNS:
		frames.append(frames[-1].copy())
	return frames[:CAPOO_SOURCE_COLUMNS]


def _build_capoo_sheet(source: Image.Image, source_row: int) -> Image.Image:
	sheet = Image.new("RGBA", (CAPOO_FRAME_SIZE * 4, CAPOO_FRAME_SIZE * 4), (0, 0, 0, 0))
	source_frames = _extract_capoo_row_frames(source, source_row)

	for source_column, cell in enumerate(source_frames):
		frame = _fit_subject_to_frame(
			cell,
			(CAPOO_FRAME_SIZE, CAPOO_FRAME_SIZE),
			(CAPOO_VISIBLE_SIZE, CAPOO_VISIBLE_SIZE),
		)
		output_row = 0 if source_column < 4 else (1 if source_column < 8 else 3)
		output_column = source_column % 4
		sheet.alpha_composite(frame, (output_column * CAPOO_FRAME_SIZE, output_row * CAPOO_FRAME_SIZE))

	for output_column in range(4):
		windup_frame = sheet.crop(
			(
				output_column * CAPOO_FRAME_SIZE,
				CAPOO_FRAME_SIZE,
				(output_column + 1) * CAPOO_FRAME_SIZE,
				CAPOO_FRAME_SIZE * 2,
			)
		)
		sheet.alpha_composite(windup_frame, (output_column * CAPOO_FRAME_SIZE, CAPOO_FRAME_SIZE * 2))
	return sheet


def _find_fireball_core_anchor(subject: Image.Image) -> tuple[float, float]:
	array = np.array(subject.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	red = array[:, :, 0].astype(np.int16)
	green = array[:, :, 1].astype(np.int16)
	blue = array[:, :, 2].astype(np.int16)
	core = alpha & (red >= 220) & (green >= 145) & (blue <= 120)
	if not core.any():
		bbox = _subject_bbox(subject)
		if bbox is None:
			return (subject.width * 0.5, subject.height * 0.5)
		return ((bbox[0] + bbox[2]) * 0.5, (bbox[1] + bbox[3]) * 0.5)
	ys, xs = np.nonzero(core)
	return (float(xs.mean()), float(ys.mean()))


def _remove_small_alpha_components(image: Image.Image, min_pixels: int) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	if not alpha.any():
		return image
	labels, _count = ndimage.label(alpha, structure=np.ones((3, 3), dtype=bool))
	keep = np.zeros(alpha.shape, dtype=bool)
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		component = labels[slices] == label_index
		if int(component.sum()) < min_pixels:
			continue
		keep[slices] |= component
	array[~keep] = (0, 0, 0, 0)
	return Image.fromarray(array)


def _build_fireball_fly_row(source: Image.Image) -> Image.Image:
	cells = [
		_crop_grid_cell(source, FIREBALL_FRAME_COUNT, 3, column, 0)
		for column in range(FIREBALL_FRAME_COUNT)
	]
	subjects: list[Image.Image] = []
	for cell in cells:
		bbox = _subject_bbox(cell)
		if bbox is None:
			subjects.append(Image.new("RGBA", (1, 1), (0, 0, 0, 0)))
		else:
			subjects.append(_remove_small_alpha_components(cell.crop(bbox), 30))

	max_width = max(subject.width for subject in subjects)
	max_height = max(subject.height for subject in subjects)
	scale = min(
		FIREBALL_VISIBLE_SIZE / float(max_width),
		FIREBALL_VISIBLE_SIZE / float(max_height),
		1.0,
	)
	sheet = Image.new("RGBA", (FIREBALL_FRAME_SIZE * FIREBALL_FRAME_COUNT, FIREBALL_FRAME_SIZE), (0, 0, 0, 0))
	for index, subject in enumerate(subjects):
		output_size = (
			max(1, round(subject.width * scale)),
			max(1, round(subject.height * scale)),
		)
		resized = subject.resize(output_size, Image.Resampling.NEAREST)
		core_x, core_y = _find_fireball_core_anchor(resized)
		frame = Image.new("RGBA", (FIREBALL_FRAME_SIZE, FIREBALL_FRAME_SIZE), (0, 0, 0, 0))
		frame.alpha_composite(
			resized,
			(
				round(38.0 - core_x),
				round(32.0 - core_y),
			),
		)
		sheet.alpha_composite(frame, (index * FIREBALL_FRAME_SIZE, 0))
	return sheet


def _build_fireball_impact_row(source: Image.Image) -> Image.Image:
	sheet = Image.new("RGBA", (FIREBALL_FRAME_SIZE * FIREBALL_FRAME_COUNT, FIREBALL_FRAME_SIZE), (0, 0, 0, 0))
	for column in range(FIREBALL_FRAME_COUNT):
		cell = _crop_grid_cell(source, FIREBALL_FRAME_COUNT, 1, column, 0)
		bbox = _subject_bbox(cell)
		if bbox is None:
			continue
		subject = cell.crop(bbox)
		scale = min(
			FIREBALL_IMPACT_VISIBLE_SIZE / float(subject.width),
			FIREBALL_IMPACT_VISIBLE_SIZE / float(subject.height),
			1.0,
		)
		output_size = (
			max(1, round(subject.width * scale)),
			max(1, round(subject.height * scale)),
		)
		resized = subject.resize(output_size, Image.Resampling.NEAREST)
		frame = Image.new("RGBA", (FIREBALL_FRAME_SIZE, FIREBALL_FRAME_SIZE), (0, 0, 0, 0))
		frame.alpha_composite(
			resized,
			(
				round((FIREBALL_FRAME_SIZE - output_size[0]) / 2.0),
				round((FIREBALL_FRAME_SIZE - output_size[1]) / 2.0),
			),
		)
		sheet.alpha_composite(frame, (column * FIREBALL_FRAME_SIZE, 0))
	return sheet


def _build_fireball_sheet(source: Image.Image, impact_source: Image.Image) -> Image.Image:
	sheet = Image.new(
		"RGBA",
		(FIREBALL_FRAME_SIZE * FIREBALL_FRAME_COUNT, FIREBALL_FRAME_SIZE * 2),
		(0, 0, 0, 0),
	)
	sheet.alpha_composite(_build_fireball_fly_row(source), (0, 0))
	sheet.alpha_composite(_build_fireball_impact_row(impact_source), (0, FIREBALL_FRAME_SIZE))
	return sheet


def _build_smg_bullet_sheet(source: Image.Image) -> Image.Image:
	sheet = Image.new("RGBA", (SMG_BULLET_FRAME_WIDTH * SMG_BULLET_FRAME_COUNT, SMG_BULLET_FRAME_HEIGHT), (0, 0, 0, 0))
	for column in range(SMG_BULLET_FRAME_COUNT):
		cell = _crop_grid_cell(source, SMG_BULLET_FRAME_COUNT, 3, column, 1)
		frame = _fit_subject_to_frame(
			cell,
			(SMG_BULLET_FRAME_WIDTH, SMG_BULLET_FRAME_HEIGHT),
			(SMG_BULLET_FRAME_WIDTH - 1, SMG_BULLET_FRAME_HEIGHT - 1),
		)
		sheet.alpha_composite(frame, (column * SMG_BULLET_FRAME_WIDTH, 0))
	return sheet


def _build_reticle_texture(source: Image.Image) -> Image.Image:
	cell = _crop_grid_cell(source, 1, 3, 0, 2)
	return _fit_subject_to_frame(
		cell,
		(RETICLE_SIZE, RETICLE_SIZE),
		(RETICLE_SIZE - 2, RETICLE_SIZE - 2),
	)


def _remove_magenta_residue(image: Image.Image) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	red = array[:, :, 0].astype(np.int16)
	green = array[:, :, 1].astype(np.int16)
	blue = array[:, :, 2].astype(np.int16)
	residue = (
		alpha
		& (red >= 72)
		& (blue >= 72)
		& (green <= 118)
		& ((red + blue - green * 2) >= 70)
	)
	array[residue] = (0, 0, 0, 0)
	return Image.fromarray(array)


def _write_capoo_frames(name: str, frame_size: tuple[int, int] | None = None) -> None:
	if frame_size == None:
		frame_size = (CAPOO_FRAME_SIZE, CAPOO_FRAME_SIZE)
	frame_width, frame_height = frame_size
	texture_path = f"res://resources/texture/{name}.png"
	resource_uid = SPRITE_FRAME_UIDS.get(name, "")
	texture_uid = TEXTURE_UIDS.get(name, "")
	resource_header = (
		f"[gd_resource type=\"SpriteFrames\" format=3 uid=\"{resource_uid}\"]"
		if resource_uid
		else "[gd_resource type=\"SpriteFrames\" format=3]"
	)
	texture_ext_resource = (
		f"[ext_resource type=\"Texture2D\" uid=\"{texture_uid}\" path=\"{texture_path}\" id=\"1_texture\"]"
		if texture_uid
		else f"[ext_resource type=\"Texture2D\" path=\"{texture_path}\" id=\"1_texture\"]"
	)
	lines = [
		resource_header,
		"",
		texture_ext_resource,
		"",
	]

	for animation_name in CAPOO_ANIMATION_WRITE_ORDER:
		row = CAPOO_ANIMATION_ROWS[animation_name]
		for column in range(4):
			lines.extend(
				[
					f"[sub_resource type=\"AtlasTexture\" id=\"AtlasTexture_{animation_name}_{column}\"]",
					"atlas = ExtResource(\"1_texture\")",
					f"region = Rect2({column * frame_width}, {row * frame_height}, {frame_width}, {frame_height})",
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
	for animation_name in CAPOO_ANIMATION_WRITE_ORDER:
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
	(ANIMATION_DIR / f"{name}.tres").write_text("\n".join(lines), encoding="utf-8", newline="\n")


def _write_fireball_frames() -> None:
	texture_path = "res://resources/texture/capoo_mage_fireball.png"
	lines = [
		f"[gd_resource type=\"SpriteFrames\" format=3 uid=\"{FIREBALL_SPRITE_FRAMES_UID}\"]",
		"",
		f"[ext_resource type=\"Texture2D\" uid=\"{FIREBALL_TEXTURE_UID}\" path=\"{texture_path}\" id=\"1_texture\"]",
		"",
	]
	for animation_name, row in [("fly", 0), ("impact", 1)]:
		for column in range(FIREBALL_FRAME_COUNT):
			lines.extend(
				[
					f"[sub_resource type=\"AtlasTexture\" id=\"AtlasTexture_{animation_name}_{column}\"]",
					"atlas = ExtResource(\"1_texture\")",
					f"region = Rect2({column * FIREBALL_FRAME_SIZE}, {row * FIREBALL_FRAME_SIZE}, {FIREBALL_FRAME_SIZE}, {FIREBALL_FRAME_SIZE})",
					"",
				]
			)

	entries: list[str] = []
	for animation_name, speed, loop in [("fly", 12.0, True), ("impact", 24.0, False)]:
		frame_entries = [
			"{\n\"duration\": 1.0,\n"
			f"\"texture\": SubResource(\"AtlasTexture_{animation_name}_{column}\")\n}}"
			for column in range(FIREBALL_FRAME_COUNT)
		]
		entries.append(
			"{\n"
			f"\"frames\": [{', '.join(frame_entries)}],\n"
			f"\"loop\": {str(loop).lower()},\n"
			f"\"name\": &\"{animation_name}\",\n"
			f"\"speed\": {speed:.1f}\n"
			"}"
		)
	lines.append("[resource]")
	lines.append(f"animations = [{', '.join(entries)}]")
	lines.append("")
	(ANIMATION_DIR / "capoo_mage_fireball.tres").write_text("\n".join(lines), encoding="utf-8", newline="\n")


def _write_smg_bullet_frames() -> None:
	_write_linear_frames(
		"capoo_smg_bullet",
		"fly",
		SMG_BULLET_FRAME_COUNT,
		SMG_BULLET_FRAME_WIDTH,
		SMG_BULLET_FRAME_HEIGHT,
		18.0,
	)


def _write_linear_frames(
	name: str,
	animation_name: str,
	frame_count: int,
	frame_width: int,
	frame_height: int,
	speed: float,
) -> None:
	texture_path = f"res://resources/texture/{name}.png"
	lines = [
		"[gd_resource type=\"SpriteFrames\" format=3]",
		"",
		f"[ext_resource type=\"Texture2D\" path=\"{texture_path}\" id=\"1_texture\"]",
		"",
	]
	for column in range(frame_count):
		lines.extend(
			[
				f"[sub_resource type=\"AtlasTexture\" id=\"AtlasTexture_{animation_name}_{column}\"]",
				"atlas = ExtResource(\"1_texture\")",
				f"region = Rect2({column * frame_width}, 0, {frame_width}, {frame_height})",
				"",
			]
		)
	frame_entries = [
		"{\n\"duration\": 1.0,\n"
		f"\"texture\": SubResource(\"AtlasTexture_{animation_name}_{column}\")\n}}"
		for column in range(frame_count)
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
	(ANIMATION_DIR / f"{name}.tres").write_text("\n".join(lines), encoding="utf-8", newline="\n")


def _save_debug(name: str, image: Image.Image) -> None:
	DEBUG_DIR.mkdir(parents=True, exist_ok=True)
	image.save(DEBUG_DIR / f"{name}.png")


def main() -> None:
	if not CAPOO_SOURCE.is_file():
		raise FileNotFoundError(CAPOO_SOURCE)
	if not PROJECTILE_SOURCE.is_file():
		raise FileNotFoundError(PROJECTILE_SOURCE)
	if not FIREBALL_IMPACT_SOURCE.is_file():
		raise FileNotFoundError(FIREBALL_IMPACT_SOURCE)

	TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
	ANIMATION_DIR.mkdir(parents=True, exist_ok=True)

	capoo_source = _remove_chroma_background(Image.open(CAPOO_SOURCE), "magenta")
	projectile_source = _remove_chroma_background(Image.open(PROJECTILE_SOURCE), "green")
	fireball_impact_source = _remove_chroma_background(Image.open(FIREBALL_IMPACT_SOURCE), "green")
	_save_debug("capoo_variants_v2_alpha", capoo_source)
	_save_debug("capoo_projectiles_v2_alpha", projectile_source)
	_save_debug("capoo_mage_fireball_impact_alpha", fireball_impact_source)

	for name, row in CAPOO_VARIANTS.items():
		sheet = _build_capoo_sheet(capoo_source, row)
		if name in ("capoo_sniper", "capoo_smg"):
			sheet = _remove_magenta_residue(sheet)
		sheet.save(TEXTURE_DIR / f"{name}.png")
		_write_capoo_frames(name)
		print(f"{name}: {sheet.width}x{sheet.height}, bbox={sheet.getchannel('A').getbbox()}")

	fireball_sheet = _build_fireball_sheet(projectile_source, fireball_impact_source)
	fireball_sheet.save(TEXTURE_DIR / "capoo_mage_fireball.png")
	_write_fireball_frames()
	print(f"capoo_mage_fireball: {fireball_sheet.width}x{fireball_sheet.height}, bbox={fireball_sheet.getchannel('A').getbbox()}")

	smg_bullet_sheet = _build_smg_bullet_sheet(projectile_source)
	smg_bullet_sheet.save(TEXTURE_DIR / "capoo_smg_bullet.png")
	_write_smg_bullet_frames()
	print(f"capoo_smg_bullet: {smg_bullet_sheet.width}x{smg_bullet_sheet.height}, bbox={smg_bullet_sheet.getchannel('A').getbbox()}")

	reticle = _build_reticle_texture(projectile_source)
	reticle.save(TEXTURE_DIR / "capoo_sniper_lock_reticle.png")
	print(f"capoo_sniper_lock_reticle: {reticle.width}x{reticle.height}, bbox={reticle.getchannel('A').getbbox()}")


if __name__ == "__main__":
	main()
