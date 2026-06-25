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
	CAPOO_ANIMATION_WRITE_ORDER,
	CAPOO_ANIMATION_ROWS,
	CAPOO_FRAME_SIZE,
	DEBUG_DIR,
	SPRITE_FRAME_UIDS,
	TEXTURE_UIDS,
	TEXTURE_DIR,
	_remove_chroma_background,
	_remove_magenta_residue,
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
		"path": ROOT / "dev_assets/source_images/capoo_sniper_generated_v4.png",
		"key": "magenta",
		"frame_size": (128, 96),
		"body_anchor_target": (48.0, 67.0),
		"component_row_slicing": True,
	},
	"capoo_smg": {
		"path": ROOT / "dev_assets/source_images/capoo_smg_generated_v1.png",
		"key": "magenta",
		"component_row_slicing": True,
	},
}

GRID_COLUMNS = 4
GRID_ROWS = 4
FRAME_MARGIN = 4
BODY_TARGET_HEIGHT = 48.0
BODY_ANCHOR_TARGET = (48.0, 67.0)
DEFAULT_FRAME_SIZE = (CAPOO_FRAME_SIZE, CAPOO_FRAME_SIZE)
COMPONENT_MIN_PIXELS = 12


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


def _fit_with_body_anchor(
	cell: Image.Image,
	frame_size: tuple[int, int],
	body_anchor_target: tuple[float, float],
) -> Image.Image:
	bbox = _subject_bbox(cell)
	frame = Image.new("RGBA", frame_size, (0, 0, 0, 0))
	if bbox == None:
		return frame

	subject = cell.crop(bbox)
	(body_anchor_x, body_anchor_y), body_height = _body_anchor_and_height(subject)
	scale = BODY_TARGET_HEIGHT / body_height
	scale = min(scale, _max_scale_for_anchor(subject, body_anchor_x, body_anchor_y, frame_size, body_anchor_target))
	output_size = (
		max(1, round(subject.width * scale)),
		max(1, round(subject.height * scale)),
	)
	resized = subject.resize(output_size, Image.Resampling.NEAREST)
	paste_position = (
		round(body_anchor_target[0] - body_anchor_x * scale),
		round(body_anchor_target[1] - body_anchor_y * scale),
	)
	frame.alpha_composite(resized, paste_position)
	return frame


def _max_scale_for_anchor(
	subject: Image.Image,
	anchor_x: float,
	anchor_y: float,
	frame_size: tuple[int, int],
	body_anchor_target: tuple[float, float],
) -> float:
	limits: list[float] = []
	if anchor_x > 0.0:
		limits.append((body_anchor_target[0] - FRAME_MARGIN) / anchor_x)
	if subject.width - anchor_x > 0.0:
		limits.append((frame_size[0] - FRAME_MARGIN - body_anchor_target[0]) / (subject.width - anchor_x))
	if anchor_y > 0.0:
		limits.append((body_anchor_target[1] - FRAME_MARGIN) / anchor_y)
	if subject.height - anchor_y > 0.0:
		limits.append((frame_size[1] - FRAME_MARGIN - body_anchor_target[1]) / (subject.height - anchor_y))
	return max(0.1, min(limits)) if limits else 1.0


def _build_single_capoo_sheet(
	source: Image.Image,
	frame_size: tuple[int, int],
	body_anchor_target: tuple[float, float],
	component_row_slicing: bool,
) -> Image.Image:
	sheet = Image.new("RGBA", (frame_size[0] * GRID_COLUMNS, frame_size[1] * GRID_ROWS), (0, 0, 0, 0))
	for row in range(GRID_ROWS):
		row_cells = _component_owned_row_cells(source, row) if component_row_slicing else None
		for column in range(GRID_COLUMNS):
			cell = row_cells[column] if row_cells != None else _crop_grid_cell(source, column, row)
			frame = _fit_with_body_anchor(cell, frame_size, body_anchor_target)
			frame = _realign_frame_body_anchor(frame, body_anchor_target)
			sheet.alpha_composite(frame, (column * frame_size[0], row * frame_size[1]))
	return sheet


def _component_owned_row_cells(source: Image.Image, row: int) -> list[Image.Image]:
	row_top = round(row * source.height / float(GRID_ROWS))
	row_bottom = round((row + 1) * source.height / float(GRID_ROWS))
	row_image = source.crop((0, row_top, source.width, row_bottom)).convert("RGBA")
	row_array = np.array(row_image, dtype=np.uint8)
	visible = row_array[:, :, 3] > 0
	labels, _count = ndimage.label(visible, structure=np.ones((3, 3), dtype=bool))
	components = _row_components(labels)
	body_bboxes = _row_body_bboxes(source, row, row_top)

	assignments: dict[int, int] = {}
	primary_bboxes: list[tuple[int, int, int, int] | None] = [None] * GRID_COLUMNS
	for label_index, _area, bbox in components:
		overlaps = [_bbox_overlap_area(bbox, body_bbox) for body_bbox in body_bboxes]
		best_column = int(np.argmax(overlaps))
		if overlaps[best_column] <= 0:
			continue
		assignments[label_index] = best_column
		primary_bboxes[best_column] = _bbox_union(primary_bboxes[best_column], bbox)

	target_bboxes = [
		primary_bboxes[column] if primary_bboxes[column] != None else body_bboxes[column]
		for column in range(GRID_COLUMNS)
	]
	for label_index, _area, bbox in components:
		if label_index in assignments:
			continue
		assignments[label_index] = min(
			range(GRID_COLUMNS),
			key=lambda column: _bbox_distance_squared(bbox, target_bboxes[column]),
		)

	cells: list[Image.Image] = []
	for column in range(GRID_COLUMNS):
		owned_labels = [label_index for label_index, owner in assignments.items() if owner == column]
		owned_mask = np.isin(labels, owned_labels) if owned_labels else np.zeros(labels.shape, dtype=bool)
		owned_array = np.zeros_like(row_array)
		owned_array[owned_mask] = row_array[owned_mask]
		cells.append(Image.fromarray(owned_array))
	return cells


def _row_components(labels: np.ndarray) -> list[tuple[int, int, tuple[int, int, int, int]]]:
	components: list[tuple[int, int, tuple[int, int, int, int]]] = []
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		component = labels[slices] == label_index
		area = int(component.sum())
		if area < COMPONENT_MIN_PIXELS:
			continue
		local_y, local_x = np.nonzero(component)
		bbox = (
			int(local_x.min() + slices[1].start),
			int(local_y.min() + slices[0].start),
			int(local_x.max() + slices[1].start + 1),
			int(local_y.max() + slices[0].start + 1),
		)
		components.append((label_index, area, bbox))
	return components


def _row_body_bboxes(source: Image.Image, row: int, row_top: int) -> list[tuple[int, int, int, int]]:
	body_bboxes: list[tuple[int, int, int, int]] = []
	for column in range(GRID_COLUMNS):
		left, top, right, bottom = _grid_cell_bounds(source, column, row)
		cell = source.crop((left, top, right, bottom))
		body_bbox = _largest_mask_bbox(_body_mask(cell))
		if body_bbox == None:
			body_bboxes.append((left, top - row_top, right, bottom - row_top))
			continue
		body_bboxes.append((
			left + body_bbox[0],
			top - row_top + body_bbox[1],
			left + body_bbox[2],
			top - row_top + body_bbox[3],
		))
	return body_bboxes


def _bbox_overlap_area(
	a: tuple[int, int, int, int],
	b: tuple[int, int, int, int],
) -> int:
	left = max(a[0], b[0])
	top = max(a[1], b[1])
	right = min(a[2], b[2])
	bottom = min(a[3], b[3])
	return max(0, right - left) * max(0, bottom - top)


def _bbox_union(
	a: tuple[int, int, int, int] | None,
	b: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
	if a == None:
		return b
	return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def _bbox_distance_squared(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> int:
	dx = max(b[0] - a[2], a[0] - b[2], 0)
	dy = max(b[1] - a[3], a[1] - b[3], 0)
	return dx * dx + dy * dy


def _realign_frame_body_anchor(frame: Image.Image, body_anchor_target: tuple[float, float]) -> Image.Image:
	anchor, _height = _body_anchor_and_height(frame)
	offset = (
		round(body_anchor_target[0] - anchor[0]),
		round(body_anchor_target[1] - anchor[1]),
	)
	if offset == (0, 0):
		return frame
	realigned = Image.new("RGBA", frame.size, (0, 0, 0, 0))
	realigned.alpha_composite(frame, offset)
	return realigned


def _audit_body_anchors(sheet: Image.Image, name: str, frame_size: tuple[int, int]) -> None:
	print(f"{name} body anchors:")
	for row_name, row in [("move", 0), ("windup", 1), ("attack", 2), ("death", 3)]:
		anchors: list[tuple[float, float]] = []
		for column in range(GRID_COLUMNS):
			frame = sheet.crop((
				column * frame_size[0],
				row * frame_size[1],
				(column + 1) * frame_size[0],
				(row + 1) * frame_size[1],
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

	for animation_name in CAPOO_ANIMATION_WRITE_ORDER:
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

	frame_size = source_config.get("frame_size", DEFAULT_FRAME_SIZE)
	body_anchor_target = source_config.get("body_anchor_target", BODY_ANCHOR_TARGET)
	component_row_slicing = bool(source_config.get("component_row_slicing", False))
	sheet = _build_single_capoo_sheet(alpha_source, frame_size, body_anchor_target, component_row_slicing)
	if source_config["key"] == "magenta":
		sheet = _remove_magenta_residue(sheet)
	sheet.save(TEXTURE_DIR / f"{name}.png")
	_write_capoo_frames(name, frame_size=frame_size)
	_audit_body_anchors(sheet, name, frame_size)
	print(f"{name}: {sheet.width}x{sheet.height}, bbox={sheet.getchannel('A').getbbox()}")


def main() -> None:
	parser = argparse.ArgumentParser(description="Process one generated Capoo sprite sheet.")
	parser.add_argument("name", choices=sorted(SINGLE_SOURCES.keys()))
	args = parser.parse_args()
	process_capoo(args.name)


if __name__ == "__main__":
	main()
