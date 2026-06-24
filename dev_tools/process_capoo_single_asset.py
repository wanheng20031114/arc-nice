#!/usr/bin/env python3
"""Process one generated Capoo sprite sheet at a time."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from process_capoo_variant_assets import (
	ANIMATION_DIR,
	CAPOO_ANIMATION_ROWS,
	CAPOO_FRAME_SIZE,
	DEBUG_DIR,
	SPRITE_FRAME_UIDS,
	TEXTURE_UIDS,
	TEXTURE_DIR,
	_remove_chroma_background,
	_save_debug,
	_subject_bbox,
	_write_capoo_frames,
)


ROOT = Path(__file__).resolve().parents[1]

SINGLE_SOURCES = {
	"capoo_mage": {
		"path": ROOT / "dev_assets/source_images/capoo_mage_generated_v3.png",
		"key": "green",
		"alpha_path": ROOT / "tmp/capoo_variant_assets/capoo_mage_single_alpha.png",
		"direct_alpha_sheet": True,
		"direct_frame_size": (374, 300),
		"direct_body_anchor": (160, 244),
	},
	"capoo_sniper": {
		"path": ROOT / "dev_assets/source_images/capoo_sniper_generated_v3.png",
		"key": "magenta",
	},
}

GRID_COLUMNS = 4
GRID_ROWS = 4
FRAME_MARGIN = 4
BODY_TARGET_HEIGHT = 48.0
BODY_ANCHOR_TARGET = (48.0, 67.0)


def _grid_cell_bounds(sheet: Image.Image, column: int, row: int) -> tuple[int, int, int, int]:
	cell_width = sheet.width / float(GRID_COLUMNS)
	cell_height = sheet.height / float(GRID_ROWS)
	left = round(column * cell_width)
	top = round(row * cell_height)
	right = round((column + 1) * cell_width)
	bottom = round((row + 1) * cell_height)
	return (left, top, right, bottom)


def _crop_grid_cell(sheet: Image.Image, column: int, row: int) -> Image.Image:
	return sheet.crop(_grid_cell_bounds(sheet, column, row))


def _body_mask(image: Image.Image) -> np.ndarray:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	red = array[:, :, 0].astype(np.int16)
	green = array[:, :, 1].astype(np.int16)
	blue = array[:, :, 2].astype(np.int16)

	return alpha & (blue >= 120) & (green >= 85) & (red <= 190) & ((blue - red) >= 18)


def _largest_mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int] | None:
	labels, _count = ndimage.label(mask, structure=np.ones((3, 3), dtype=bool))
	best_area = 0
	best_bbox: tuple[int, int, int, int] | None = None
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		component = labels[slices] == label_index
		area = int(component.sum())
		if area <= best_area:
			continue
		local_y, local_x = np.nonzero(component)
		best_area = area
		best_bbox = (
			int(local_x.min() + slices[1].start),
			int(local_y.min() + slices[0].start),
			int(local_x.max() + slices[1].start + 1),
			int(local_y.max() + slices[0].start + 1),
		)
	return best_bbox


def _body_anchor_and_height(image: Image.Image) -> tuple[tuple[float, float], float]:
	body_bbox = _largest_mask_bbox(_body_mask(image))
	if body_bbox != None:
		body_height = max(1.0, float(body_bbox[3] - body_bbox[1]))
		return (((body_bbox[0] + body_bbox[2]) * 0.5, float(body_bbox[3])), body_height)

	bbox = _subject_bbox(image)
	if bbox == None:
		return ((image.width * 0.5, image.height * 0.5), 1.0)
	return (((bbox[0] + bbox[2]) * 0.5, float(bbox[3])), max(1.0, float(bbox[3] - bbox[1])))


def _fit_with_body_anchor(cell: Image.Image) -> Image.Image:
	bbox = _subject_bbox(cell)
	frame = Image.new("RGBA", (CAPOO_FRAME_SIZE, CAPOO_FRAME_SIZE), (0, 0, 0, 0))
	if bbox == None:
		return frame

	subject = cell.crop(bbox)
	(body_anchor_x, body_anchor_y), body_height = _body_anchor_and_height(subject)
	scale = BODY_TARGET_HEIGHT / body_height
	scale = min(scale, _max_scale_for_anchor(subject, body_anchor_x, body_anchor_y))
	output_size = (
		max(1, round(subject.width * scale)),
		max(1, round(subject.height * scale)),
	)
	resized = subject.resize(output_size, Image.Resampling.NEAREST)
	paste_position = (
		round(BODY_ANCHOR_TARGET[0] - body_anchor_x * scale),
		round(BODY_ANCHOR_TARGET[1] - body_anchor_y * scale),
	)
	frame.alpha_composite(resized, paste_position)
	return frame


def _max_scale_for_anchor(subject: Image.Image, anchor_x: float, anchor_y: float) -> float:
	limits: list[float] = []
	if anchor_x > 0.0:
		limits.append((BODY_ANCHOR_TARGET[0] - FRAME_MARGIN) / anchor_x)
	if subject.width - anchor_x > 0.0:
		limits.append((CAPOO_FRAME_SIZE - FRAME_MARGIN - BODY_ANCHOR_TARGET[0]) / (subject.width - anchor_x))
	if anchor_y > 0.0:
		limits.append((BODY_ANCHOR_TARGET[1] - FRAME_MARGIN) / anchor_y)
	if subject.height - anchor_y > 0.0:
		limits.append((CAPOO_FRAME_SIZE - FRAME_MARGIN - BODY_ANCHOR_TARGET[1]) / (subject.height - anchor_y))
	return max(0.1, min(limits)) if limits else 1.0


def _build_single_capoo_sheet(source: Image.Image) -> Image.Image:
	sheet = Image.new("RGBA", (CAPOO_FRAME_SIZE * GRID_COLUMNS, CAPOO_FRAME_SIZE * GRID_ROWS), (0, 0, 0, 0))
	for row in range(GRID_ROWS):
		for column in range(GRID_COLUMNS):
			cell = _crop_grid_cell(source, column, row)
			frame = _fit_with_body_anchor(cell)
			frame = _realign_frame_body_anchor(frame)
			sheet.alpha_composite(frame, (column * CAPOO_FRAME_SIZE, row * CAPOO_FRAME_SIZE))
	return sheet


def _realign_frame_body_anchor(frame: Image.Image) -> Image.Image:
	anchor, _height = _body_anchor_and_height(frame)
	offset = (
		round(BODY_ANCHOR_TARGET[0] - anchor[0]),
		round(BODY_ANCHOR_TARGET[1] - anchor[1]),
	)
	if offset == (0, 0):
		return frame
	realigned = Image.new("RGBA", frame.size, (0, 0, 0, 0))
	realigned.alpha_composite(frame, offset)
	return realigned


def _audit_body_anchors(sheet: Image.Image, name: str) -> None:
	print(f"{name} body anchors:")
	for row_name, row in [("move", 0), ("windup", 1), ("attack", 2), ("death", 3)]:
		anchors: list[tuple[float, float]] = []
		for column in range(GRID_COLUMNS):
			frame = sheet.crop((
				column * CAPOO_FRAME_SIZE,
				row * CAPOO_FRAME_SIZE,
				(column + 1) * CAPOO_FRAME_SIZE,
				(row + 1) * CAPOO_FRAME_SIZE,
			))
			anchor, _height = _body_anchor_and_height(frame)
			anchors.append((round(anchor[0], 2), round(anchor[1], 2)))
		print(f"  {row_name}: {anchors}")


def _build_direct_alpha_sheet_regions(
	source: Image.Image,
	frame_size: tuple[int, int],
	body_anchor: tuple[int, int],
) -> dict[str, list[tuple[tuple[int, int, int, int], tuple[int, int, int, int]]]]:
	regions: dict[str, list[tuple[tuple[int, int, int, int], tuple[int, int, int, int]]]] = {}
	for animation_name, row in CAPOO_ANIMATION_ROWS.items():
		animation_regions: list[tuple[tuple[int, int, int, int], tuple[int, int, int, int]]] = []
		for column in range(GRID_COLUMNS):
			cell_bounds = _grid_cell_bounds(source, column, row)
			cell = source.crop(cell_bounds)
			(local_anchor_x, local_anchor_y), _height = _body_anchor_and_height(cell)
			global_anchor_x = cell_bounds[0] + local_anchor_x
			global_anchor_y = cell_bounds[1] + local_anchor_y
			target_region = (
				round(global_anchor_x - body_anchor[0]),
				round(global_anchor_y - body_anchor[1]),
				frame_size[0],
				frame_size[1],
			)
			region = _intersect_rect(target_region, cell_bounds)
			margin = (
				region[0] - target_region[0],
				region[1] - target_region[1],
				frame_size[0] - region[2],
				frame_size[1] - region[3],
			)
			_validate_direct_alpha_region(source, cell_bounds, region, animation_name, column)
			animation_regions.append((region, margin))
		regions[animation_name] = animation_regions
	return regions


def _intersect_rect(
	rect: tuple[int, int, int, int],
	bounds: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
	left = max(rect[0], bounds[0])
	top = max(rect[1], bounds[1])
	right = min(rect[0] + rect[2], bounds[2])
	bottom = min(rect[1] + rect[3], bounds[3])
	if left >= right or top >= bottom:
		raise ValueError(f"Region {rect} does not intersect source cell {bounds}.")
	return (left, top, right - left, bottom - top)


def _validate_direct_alpha_region(
	source: Image.Image,
	cell_bounds: tuple[int, int, int, int],
	region: tuple[int, int, int, int],
	animation_name: str,
	column: int,
) -> None:
	left, top, width, height = region
	right = left + width
	bottom = top + height
	if left < 0 or top < 0 or right > source.width or bottom > source.height:
		raise ValueError(f"{animation_name}_{column} region exceeds source bounds: {region}")

	cell = source.crop(cell_bounds)
	bbox = _subject_bbox(cell)
	if bbox == None:
		raise ValueError(f"{animation_name}_{column} has no visible pixels.")
	global_bbox = (
		cell_bounds[0] + bbox[0],
		cell_bounds[1] + bbox[1],
		cell_bounds[0] + bbox[2],
		cell_bounds[1] + bbox[3],
	)
	if (
		global_bbox[0] < left
		or global_bbox[1] < top
		or global_bbox[2] > right
		or global_bbox[3] > bottom
	):
		raise ValueError(
			f"{animation_name}_{column} region {region} clips visible bbox {global_bbox}."
		)


def _write_capoo_direct_alpha_frames(
	name: str,
	regions: dict[str, list[tuple[tuple[int, int, int, int], tuple[int, int, int, int]]]],
) -> None:
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

	for animation_name in CAPOO_ANIMATION_ROWS:
		for column, (region, margin) in enumerate(regions[animation_name]):
			left, top, width, height = region
			margin_left, margin_top, margin_width, margin_height = margin
			lines.extend(
				[
					f"[sub_resource type=\"AtlasTexture\" id=\"AtlasTexture_{animation_name}_{column}\"]",
					"atlas = ExtResource(\"1_texture\")",
					f"region = Rect2({left}, {top}, {width}, {height})",
					f"margin = Rect2({margin_left}, {margin_top}, {margin_width}, {margin_height})",
					"filter_clip = true",
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


def _audit_direct_alpha_regions(
	source: Image.Image,
	name: str,
	regions: dict[str, list[tuple[tuple[int, int, int, int], tuple[int, int, int, int]]]],
) -> None:
	print(f"{name} direct-alpha frame anchors:")
	for animation_name in CAPOO_ANIMATION_ROWS:
		anchors: list[tuple[float, float]] = []
		for region, margin in regions[animation_name]:
			left, top, width, height = region
			frame = source.crop((left, top, left + width, top + height))
			anchor, _height = _body_anchor_and_height(frame)
			anchors.append((round(anchor[0] + margin[0], 2), round(anchor[1] + margin[1], 2)))
		print(f"  {animation_name}: {anchors}")


def process_capoo(name: str) -> None:
	source_config = SINGLE_SOURCES.get(name)
	if source_config == None:
		raise ValueError(f"Unsupported single Capoo: {name}")
	source_path = source_config["path"]
	alpha_path = source_config.get("alpha_path")
	if alpha_path != None and alpha_path.is_file():
		alpha_source = Image.open(alpha_path).convert("RGBA")
	elif not source_path.is_file():
		raise FileNotFoundError(source_path)
	else:
		alpha_source = _remove_chroma_background(Image.open(source_path), str(source_config["key"]))
		_save_debug(f"{name}_single_alpha", alpha_source)

	TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
	ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
	DEBUG_DIR.mkdir(parents=True, exist_ok=True)

	if source_config.get("direct_alpha_sheet", False):
		frame_size = source_config["direct_frame_size"]
		body_anchor = source_config["direct_body_anchor"]
		regions = _build_direct_alpha_sheet_regions(alpha_source, frame_size, body_anchor)
		alpha_source.save(TEXTURE_DIR / f"{name}.png")
		_write_capoo_direct_alpha_frames(name, regions)
		_audit_direct_alpha_regions(alpha_source, name, regions)
		print(f"{name}: {alpha_source.width}x{alpha_source.height}, bbox={alpha_source.getchannel('A').getbbox()}")
		return

	sheet = _build_single_capoo_sheet(alpha_source)
	sheet.save(TEXTURE_DIR / f"{name}.png")
	_write_capoo_frames(name)
	_audit_body_anchors(sheet, name)
	print(f"{name}: {sheet.width}x{sheet.height}, bbox={sheet.getchannel('A').getbbox()}")


def main() -> None:
	parser = argparse.ArgumentParser(description="Process one generated Capoo sprite sheet.")
	parser.add_argument("name", choices=sorted(SINGLE_SOURCES.keys()))
	args = parser.parse_args()
	process_capoo(args.name)


if __name__ == "__main__":
	main()
