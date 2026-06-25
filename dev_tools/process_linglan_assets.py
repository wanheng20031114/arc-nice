#!/usr/bin/env python3
"""Build Linglan boss sprites, HUD ornaments, and sakura VFX assets."""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from connected_background_remover import (
	ConnectedBackgroundOptions,
	build_sample_background_mask,
	remove_connected_background,
)


SOURCE_SHEET = "dev_assets/source_images/linglan_boss_sheet_v2_imagegen_green.png"
ALPHA_SHEET = "dev_assets/source_images/linglan_boss_sheet_v2_alpha.png"
HUD_SOURCE = "dev_assets/source_images/linglan_boss_hud_imagegen_green.png"
HUD_ALPHA = "dev_assets/source_images/linglan_boss_hud_alpha.png"
VFX_SOURCE = "dev_assets/source_images/linglan_sakura_vfx_imagegen_green.png"
VFX_ALPHA = "dev_assets/source_images/linglan_sakura_vfx_alpha.png"

OUTPUT_TEXTURE = "resources/texture/linglan.png"
OUTPUT_FRAMES = "resources/animation/linglan.tres"
OUTPUT_HEALTH_FRAME = "resources/texture/linglan_boss_health_frame.png"
OUTPUT_NAMEPLATE = "resources/texture/linglan_boss_nameplate.png"
OUTPUT_HEALTH_FILL = "resources/texture/linglan_boss_health_fill.png"
OUTPUT_PETAL = "resources/texture/linglan_sakura_petal.png"
OUTPUT_CONVERGENCE = "resources/texture/linglan_sakura_convergence.png"
OUTPUT_CONVERGENCE_FRAMES = "resources/animation/linglan_sakura_convergence.tres"

LINGLAN_TEXTURE_RESOURCE = "res://resources/texture/linglan.png"
CONVERGENCE_TEXTURE_RESOURCE = "res://resources/texture/linglan_sakura_convergence.png"
SPRITE_FRAMES_UID = "uid://ub8py66qcmfq"
TEXTURE_UID = "uid://dkt8l1h0rrh71"

SOURCE_COLUMNS = 8
SOURCE_ROWS = 3
FRAME_PADDING = 18
FRAME_SIZE_ALIGNMENT = 8
MIN_COMPONENT_ALPHA_PIXELS = 120
FRAME_GROUP_RADIUS = 8

ANIMATION_ROWS: OrderedDict[str, int] = OrderedDict(
	[
		("idle", 0),
		("move", 1),
		("die", 2),
	]
)

ANIMATION_ALIASES: OrderedDict[str, list[str]] = OrderedDict(
	[
		("move_down", [f"move_{index}" for index in range(SOURCE_COLUMNS)]),
		("move_left", [f"move_{index}" for index in range(SOURCE_COLUMNS)]),
		("move_right", [f"move_{index}" for index in range(SOURCE_COLUMNS)]),
		("move_up", [f"move_{index}" for index in range(SOURCE_COLUMNS)]),
		("idle_down", ["idle_0"]),
		("idle_left", ["idle_0"]),
		("idle_right", ["idle_0"]),
		("idle_up", ["idle_0"]),
	]
)


FrameRegion = tuple[int, int, int, int]


@dataclass(frozen=True)
class DetectedFrame:
	source_bbox: tuple[int, int, int, int]
	alpha_pixels: int


def _round_up(value: int, alignment: int) -> int:
	return ((value + alignment - 1) // alignment) * alignment


def _remove_green_background(image: Image.Image) -> Image.Image:
	return remove_connected_background(
		image,
		ConnectedBackgroundOptions(
			rgb_tolerance=96,
			hue_tolerance=0.075,
			expansion_radius=14,
			min_hue_saturation=0.35,
			green_ratio_limit=0.84,
		),
	)


def _remove_global_green_background(image: Image.Image) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	mask = build_sample_background_mask(
		array,
		ConnectedBackgroundOptions(
			rgb_tolerance=108,
			hue_tolerance=0.09,
			expansion_radius=0,
			min_hue_saturation=0.35,
			green_ratio_limit=0.9,
		),
	)
	red = array[:, :, 0].astype(np.int16)
	green = array[:, :, 1].astype(np.int16)
	blue = array[:, :, 2].astype(np.int16)
	chroma_green = (green >= 145) & (green >= red + 45) & (green >= blue + 45)
	array[mask | chroma_green] = (0, 0, 0, 0)
	visible_pixels = array[:, :, 3] > 0
	array[:, :, 3][visible_pixels] = 255
	return Image.fromarray(array)


def _detect_source_frames(source: Image.Image) -> list[list[DetectedFrame]]:
	alpha = np.array(source.getchannel("A"), dtype=np.uint8) > 0
	group_mask = ndimage.binary_dilation(
		alpha,
		structure=np.ones((FRAME_GROUP_RADIUS * 2 + 1, FRAME_GROUP_RADIUS * 2 + 1), dtype=bool),
	)
	labels, _count = ndimage.label(group_mask)
	detected: list[DetectedFrame] = []

	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		component_alpha = (labels[slices] == label_index) & alpha[slices]
		alpha_pixels = int(component_alpha.sum())
		if alpha_pixels < MIN_COMPONENT_ALPHA_PIXELS:
			continue
		local_y, local_x = np.nonzero(component_alpha)
		left_offset = slices[1].start
		top_offset = slices[0].start
		left = int(local_x.min() + left_offset)
		top = int(local_y.min() + top_offset)
		right = int(local_x.max() + left_offset + 1)
		bottom = int(local_y.max() + top_offset + 1)
		detected.append(DetectedFrame((left, top, right, bottom), alpha_pixels))

	expected_count = SOURCE_COLUMNS * SOURCE_ROWS
	if len(detected) != expected_count:
		raise ValueError(f"Expected {expected_count} Linglan frames, detected {len(detected)}.")

	def center_y(frame: DetectedFrame) -> float:
		_left, top, _right, bottom = frame.source_bbox
		return (top + bottom) * 0.5

	def center_x(frame: DetectedFrame) -> float:
		left, _top, right, _bottom = frame.source_bbox
		return (left + right) * 0.5

	sorted_by_y = sorted(detected, key=center_y)
	rows: list[list[DetectedFrame]] = []
	for row_index in range(SOURCE_ROWS):
		row = sorted(
			sorted_by_y[row_index * SOURCE_COLUMNS : (row_index + 1) * SOURCE_COLUMNS],
			key=center_x,
		)
		rows.append(row)
	return rows


def _compute_frame_size(frames: list[DetectedFrame]) -> tuple[int, int]:
	max_width = max(right - left for left, _top, right, _bottom in [frame.source_bbox for frame in frames])
	max_height = max(bottom - top for _left, top, _right, bottom in [frame.source_bbox for frame in frames])
	return (
		_round_up(max_width + FRAME_PADDING * 2, FRAME_SIZE_ALIGNMENT),
		_round_up(max_height + FRAME_PADDING * 2, FRAME_SIZE_ALIGNMENT),
	)


def _extract_frame(image: Image.Image, frame: DetectedFrame, frame_size: tuple[int, int]) -> Image.Image:
	cell = image.crop(frame.source_bbox)
	result = Image.new("RGBA", frame_size, (0, 0, 0, 0))
	result.alpha_composite(cell, ((frame_size[0] - cell.width) // 2, (frame_size[1] - cell.height) // 2))
	return result


def _collect_linglan_frames(source: Image.Image) -> tuple[list[tuple[str, Image.Image]], OrderedDict[str, list[str]]]:
	detected_by_name: OrderedDict[str, DetectedFrame] = OrderedDict()
	source_rows = _detect_source_frames(source)
	for animation_name, row in ANIMATION_ROWS.items():
		for column in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{column}"
			detected_by_name[frame_name] = source_rows[row][column]

	for frame_name, detected in detected_by_name.items():
		if detected.alpha_pixels < MIN_COMPONENT_ALPHA_PIXELS:
			raise ValueError("%s contains too little foreground alpha." % frame_name)

	frame_size = _compute_frame_size(list(detected_by_name.values()))
	frames: list[tuple[str, Image.Image]] = []
	animations: OrderedDict[str, list[str]] = OrderedDict()

	for animation_name in ANIMATION_ROWS.keys():
		frame_names: list[str] = []
		for column in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{column}"
			frames.append((frame_name, _extract_frame(source, detected_by_name[frame_name], frame_size)))
			frame_names.append(frame_name)
		animations[animation_name] = frame_names

	for animation_name, frame_names in ANIMATION_ALIASES.items():
		animations[animation_name] = frame_names

	print(f"Linglan frame canvas: {frame_size[0]}x{frame_size[1]}")
	return frames, animations


def _build_sheet(frames: list[tuple[str, Image.Image]]) -> tuple[Image.Image, dict[str, FrameRegion]]:
	frame_width = frames[0][1].width
	frame_height = frames[0][1].height
	sheet = Image.new("RGBA", (frame_width * SOURCE_COLUMNS, frame_height * SOURCE_ROWS), (0, 0, 0, 0))
	regions: dict[str, FrameRegion] = {}
	for index, (frame_name, frame) in enumerate(frames):
		column = index % SOURCE_COLUMNS
		row = index // SOURCE_COLUMNS
		x = column * frame_width
		y = row * frame_height
		sheet.alpha_composite(frame, (x, y))
		regions[frame_name] = (x, y, frame_width, frame_height)
	return sheet, regions


def _animation_speed(animation_name: str) -> float:
	if animation_name.startswith("idle"):
		return 6.0
	if animation_name == "die":
		return 8.0
	return 9.0


def _animation_loop(animation_name: str) -> bool:
	return animation_name != "die"


def _write_spriteframes(
	output_path: Path,
	texture_resource: str,
	regions: dict[str, FrameRegion],
	animations: OrderedDict[str, list[str]],
	texture_uid: str | None = None,
	frames_uid: str | None = None,
) -> None:
	header = (
		f'[gd_resource type="SpriteFrames" format=3 uid="{frames_uid}"]'
		if frames_uid
		else '[gd_resource type="SpriteFrames" format=3]'
	)
	texture_line = (
		f'[ext_resource type="Texture2D" uid="{texture_uid}" path="{texture_resource}" id="1_texture"]'
		if texture_uid
		else f'[ext_resource type="Texture2D" path="{texture_resource}" id="1_texture"]'
	)
	lines = [header, "", texture_line, ""]
	for frame_name, region in regions.items():
		lines.extend(
			[
				f'[sub_resource type="AtlasTexture" id="AtlasTexture_{frame_name}"]',
				'atlas = ExtResource("1_texture")',
				f"region = Rect2({region[0]}, {region[1]}, {region[2]}, {region[3]})",
				"",
			]
		)

	animation_entries: list[str] = []
	for animation_name, frame_names in animations.items():
		frame_entries = []
		for frame_name in frame_names:
			frame_entries.append(
				'{\n"duration": 1.0,\n'
				f'"texture": SubResource("AtlasTexture_{frame_name}")\n}}'
			)
		animation_entries.append(
			'{\n'
			f'"frames": [{", ".join(frame_entries)}],\n'
			f'"loop": {str(_animation_loop(animation_name)).lower()},\n'
			f'"name": &"{animation_name}",\n'
			f'"speed": {_animation_speed(animation_name):.1f}\n'
			'}'
		)

	lines.append("[resource]")
	lines.append(f"animations = [{', '.join(animation_entries)}]")
	lines.append("")
	output_path.write_text("\n".join(lines), encoding="utf-8")
	print(f"SpriteFrames: {output_path} ({len(animations)} animations)")


def _foreground_bbox(image: Image.Image, padding: int = 0) -> tuple[int, int, int, int]:
	bbox = image.getchannel("A").getbbox()
	if bbox is None:
		raise ValueError("Image has no visible pixels.")
	return (
		max(0, bbox[0] - padding),
		max(0, bbox[1] - padding),
		min(image.width, bbox[2] + padding),
		min(image.height, bbox[3] + padding),
	)


def _crop_band(image: Image.Image, y_range: tuple[int, int], padding: int) -> Image.Image:
	band = image.crop((0, y_range[0], image.width, y_range[1]))
	left, top, right, bottom = _foreground_bbox(band, padding)
	return band.crop((left, top, right, bottom))


def _crop_largest_component(image: Image.Image, y_range: tuple[int, int], padding: int) -> Image.Image:
	band = image.crop((0, y_range[0], image.width, y_range[1]))
	components = _component_bboxes(band)
	if not components:
		raise ValueError("No component found for requested HUD band.")
	left, top, right, bottom, _area = sorted(components, key=lambda item: item[4], reverse=True)[0]
	return band.crop(
		(
			max(0, left - padding),
			max(0, top - padding),
			min(band.width, right + padding),
			min(band.height, bottom + padding),
		)
	)


def _find_y_bands(image: Image.Image, min_gap: int = 24) -> list[tuple[int, int]]:
	alpha = np.array(image.getchannel("A"), dtype=np.uint8) > 0
	occupied_rows = np.where(alpha.any(axis=1))[0]
	if occupied_rows.size == 0:
		return []
	bands: list[tuple[int, int]] = []
	start = int(occupied_rows[0])
	previous = int(occupied_rows[0])
	for row in occupied_rows[1:]:
		row = int(row)
		if row - previous > min_gap:
			bands.append((start, previous + 1))
			start = row
		previous = row
	bands.append((start, previous + 1))
	return bands


def _write_health_fill(path: Path) -> None:
	width = 960
	height = 42
	image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
	draw = ImageDraw.Draw(image)
	for y in range(height):
		t = y / max(height - 1, 1)
		color = (
			int(235 - 90 * t),
			int(42 - 20 * t),
			int(72 - 24 * t),
			255,
		)
		draw.line((0, y, width, y), fill=color)
	draw.rectangle((0, 0, width - 1, height - 1), outline=(255, 176, 186, 255), width=2)
	image.save(path)
	print(f"Health fill: {path} ({width}x{height})")


def _process_hud(root: Path) -> None:
	source = Image.open(root / HUD_SOURCE)
	alpha = _remove_global_green_background(source)
	(root / HUD_ALPHA).parent.mkdir(parents=True, exist_ok=True)
	alpha.save(root / HUD_ALPHA)

	health_frame = _crop_band(alpha, (0, alpha.height // 2), 8)
	nameplate = _crop_largest_component(alpha, (alpha.height // 2, alpha.height), 8)

	health_path = root / OUTPUT_HEALTH_FRAME
	nameplate_path = root / OUTPUT_NAMEPLATE
	health_path.parent.mkdir(parents=True, exist_ok=True)
	health_frame.save(health_path)
	nameplate.save(nameplate_path)
	_write_health_fill(root / OUTPUT_HEALTH_FILL)
	print(f"Health frame: {health_path} ({health_frame.width}x{health_frame.height})")
	print(f"Nameplate: {nameplate_path} ({nameplate.width}x{nameplate.height})")


def _component_bboxes(image: Image.Image) -> list[tuple[int, int, int, int, int]]:
	alpha = np.array(image.getchannel("A"), dtype=np.uint8) > 0
	labels, _count = ndimage.label(alpha)
	components: list[tuple[int, int, int, int, int]] = []
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		mask = labels[slices] == label_index
		area = int(mask.sum())
		if area <= 0:
			continue
		left = int(slices[1].start)
		top = int(slices[0].start)
		right = int(slices[1].stop)
		bottom = int(slices[0].stop)
		components.append((left, top, right, bottom, area))
	return components


def _process_vfx(root: Path) -> None:
	source = Image.open(root / VFX_SOURCE)
	alpha = _remove_global_green_background(source)
	(root / VFX_ALPHA).parent.mkdir(parents=True, exist_ok=True)
	alpha.save(root / VFX_ALPHA)

	top_half = alpha.crop((0, 0, alpha.width, alpha.height // 2))
	petal_candidates = [
		component
		for component in _component_bboxes(top_half)
		if (
			component[1] < top_half.height * 0.25
			and 700 <= component[4] <= 2500
			and component[2] - component[0] <= 75
			and component[3] - component[1] <= 80
		)
	]
	if not petal_candidates:
		raise ValueError("Could not find a usable sakura petal component.")
	petal_bbox = sorted(petal_candidates, key=lambda item: (abs(item[4] - 1700), item[0]))[0]
	petal = top_half.crop(
		(
			max(0, petal_bbox[0] - 6),
			max(0, petal_bbox[1] - 6),
			min(top_half.width, petal_bbox[2] + 6),
			min(top_half.height, petal_bbox[3] + 6),
		)
	)
	petal_path = root / OUTPUT_PETAL
	petal_path.parent.mkdir(parents=True, exist_ok=True)
	petal.save(petal_path)

	frame_regions: list[Image.Image] = []
	vortex_top = alpha.height // 2
	vortex_cell_width = alpha.width // 4
	for column in range(4):
		cell = alpha.crop(
			(
				column * vortex_cell_width,
				vortex_top,
				(column + 1) * vortex_cell_width,
				alpha.height,
			)
		)
		frame_regions.append(cell.crop(_foreground_bbox(cell, 4)))

	frame_width = _round_up(max(frame.width for frame in frame_regions), FRAME_SIZE_ALIGNMENT)
	frame_height = _round_up(max(frame.height for frame in frame_regions), FRAME_SIZE_ALIGNMENT)
	sheet = Image.new("RGBA", (frame_width * len(frame_regions), frame_height), (0, 0, 0, 0))
	regions: dict[str, FrameRegion] = {}
	for index, frame in enumerate(frame_regions):
		x = index * frame_width
		y = 0
		sheet.alpha_composite(frame, (x + (frame_width - frame.width) // 2, (frame_height - frame.height) // 2))
		regions[f"converge_{index}"] = (x, y, frame_width, frame_height)

	convergence_path = root / OUTPUT_CONVERGENCE
	convergence_path.parent.mkdir(parents=True, exist_ok=True)
	sheet.save(convergence_path)
	_write_spriteframes(
		root / OUTPUT_CONVERGENCE_FRAMES,
		CONVERGENCE_TEXTURE_RESOURCE,
		regions,
		OrderedDict([("converge", list(regions.keys()))]),
	)
	print(f"Sakura petal: {petal_path} ({petal.width}x{petal.height})")
	print(f"Sakura convergence: {convergence_path} ({sheet.width}x{sheet.height})")


def _process_linglan_sprite(root: Path) -> None:
	source = Image.open(root / SOURCE_SHEET)
	alpha_source = _remove_green_background(source)
	alpha_path = root / ALPHA_SHEET
	alpha_path.parent.mkdir(parents=True, exist_ok=True)
	alpha_source.save(alpha_path)
	print(f"Linglan alpha source: {alpha_path} ({alpha_source.width}x{alpha_source.height})")

	frames, animations = _collect_linglan_frames(alpha_source)
	sheet, regions = _build_sheet(frames)

	sheet_path = root / OUTPUT_TEXTURE
	sheet_path.parent.mkdir(parents=True, exist_ok=True)
	sheet.save(sheet_path)
	print(f"Linglan sheet: {sheet_path} ({sheet.width}x{sheet.height})")

	_write_spriteframes(
		root / OUTPUT_FRAMES,
		LINGLAN_TEXTURE_RESOURCE,
		regions,
		animations,
		TEXTURE_UID,
		SPRITE_FRAMES_UID,
	)


def main() -> None:
	root = Path(__file__).resolve().parents[1]
	_process_linglan_sprite(root)
	_process_hud(root)
	_process_vfx(root)


if __name__ == "__main__":
	main()
