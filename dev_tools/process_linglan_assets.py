#!/usr/bin/env python3
"""Build Linglan boss sprites, HUD ornaments, and sakura VFX assets."""

from __future__ import annotations

import argparse
import math
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from connected_background_remover import (
	ConnectedBackgroundOptions,
	_rgb_to_hsv_arrays,
	build_sample_background_mask,
	remove_connected_background,
)


LINGLAN_ANIMATION_STRIPS: OrderedDict[str, str] = OrderedDict(
	[
		("idle", "dev_assets/source_images/boss_linglan/idle_v1_alpha.png"),
		("move", "dev_assets/source_images/boss_linglan/move_v3_alpha.png"),
	]
)
HUD_SOURCE = "dev_assets/source_images/boss_linglan/hud_imagegen_green.png"
HUD_ALPHA = "dev_assets/source_images/boss_linglan/hud_alpha.png"
VFX_SOURCE = "dev_assets/source_images/boss_linglan/sakura_vfx_imagegen_green.png"
VFX_ALPHA = "dev_assets/source_images/boss_linglan/sakura_vfx_alpha.png"
SKILL2_ROCKET_SOURCE = "dev_assets/source_images/boss_linglan/skill2_sakura_rocket_imagegen_green.png"
SKILL2_ROCKET_ALPHA = "dev_assets/source_images/boss_linglan/skill2_sakura_rocket_alpha.png"
SKILL2_EXPLOSION_SOURCE = "dev_assets/source_images/boss_linglan/skill2_sakura_explosion_imagegen_green.png"
SKILL2_EXPLOSION_ALPHA = "dev_assets/source_images/boss_linglan/skill2_sakura_explosion_alpha.png"
DIE_SOURCE = "dev_assets/source_images/boss_linglan/die_imagegen_green_v2.png"
DIE_ALPHA = "dev_assets/source_images/boss_linglan/die_v2_alpha.png"

OUTPUT_TEXTURE_DIR = "resources/texture/boss_linglan"
OUTPUT_FRAMES = "resources/animation/linglan.tres"
OUTPUT_HEALTH_FRAME = "resources/texture/boss_linglan/health_frame.png"
OUTPUT_NAMEPLATE = "resources/texture/boss_linglan/nameplate.png"
OUTPUT_HEALTH_FILL = "resources/texture/boss_linglan/health_fill.png"
OUTPUT_PETAL = "resources/texture/boss_linglan/sakura_petal.png"
OUTPUT_CONVERGENCE = "resources/texture/boss_linglan/sakura_convergence.png"
OUTPUT_CONVERGENCE_FRAMES = "resources/animation/linglan_sakura_convergence.tres"
OUTPUT_SKILL2_ROCKET = "resources/texture/boss_linglan/skill2_sakura_rocket.png"
OUTPUT_SKILL2_ROCKET_FRAMES = "resources/animation/linglan_skill2_sakura_rocket.tres"
OUTPUT_SKILL2_EXPLOSION = "resources/texture/boss_linglan/skill2_sakura_explosion.png"
OUTPUT_SKILL2_EXPLOSION_FRAMES = "resources/animation/linglan_skill2_sakura_explosion.tres"
OUTPUT_DIE = "resources/texture/boss_linglan/die.png"

CONVERGENCE_TEXTURE_RESOURCE = "res://resources/texture/boss_linglan/sakura_convergence.png"
SKILL2_ROCKET_TEXTURE_RESOURCE = "res://resources/texture/boss_linglan/skill2_sakura_rocket.png"
SKILL2_EXPLOSION_TEXTURE_RESOURCE = "res://resources/texture/boss_linglan/skill2_sakura_explosion.png"
SPRITE_FRAMES_UID = "uid://ub8py66qcmfq"

SOURCE_COLUMNS = 8
SOURCE_ROWS = 1
SKILL2_EXPLOSION_COLUMNS = 4
SKILL2_EXPLOSION_ROWS = 4
SKILL2_ROCKET_FRAME_SIZE = (192, 96)
SKILL2_ROCKET_MAX_FOREGROUND_SIZE = (166, 66)
SKILL2_EXPLOSION_FRAME_SIZE = (256, 256)
FRAME_PADDING = 32
FRAME_SIZE_ALIGNMENT = 8
MIN_COMPONENT_ALPHA_PIXELS = 120
FRAME_GROUP_RADIUS = 8
LINGLAN_AUTHORED_FRAME_SIZE = (368, 400)
LINGLAN_DIE_TARGET_ANCHOR = (184, 380)
LINGLAN_DIE_BASE_SCALE = 1.22
LINGLAN_DIE_BAND_GAP = 30

LINGLAN_TEXTURE_UIDS: dict[str, str] = {
	"idle": "uid://bvv7p5if14s8v",
	"move": "uid://c5c85r1wfluct",
	"die": "uid://2ku0adg2fswq",
}

LINGLAN_TEXTURE_RESOURCES: OrderedDict[str, str] = OrderedDict(
	[
		("idle", "res://resources/texture/boss_linglan/idle.png"),
		("move", "res://resources/texture/boss_linglan/move.png"),
		("die", "res://resources/texture/boss_linglan/die.png"),
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


def _remove_linglan_sprite_background(image: Image.Image) -> Image.Image:
	result = remove_connected_background(
		image,
		ConnectedBackgroundOptions(
			rgb_tolerance=88,
			hue_tolerance=0.085,
			expansion_radius=18,
			min_hue_saturation=0.30,
			green_ratio_limit=1.15,
		),
	)
	array = np.array(result.convert("RGBA"), dtype=np.uint8)
	rgb_float = array[:, :, :3].astype(np.float32) / 255.0
	hue, saturation, value = _rgb_to_hsv_arrays(rgb_float)
	magenta_background = (
		(saturation >= 0.28)
		& (value >= 0.14)
		& (hue >= 0.76)
		& (hue <= 0.94)
	)
	array[magenta_background] = (0, 0, 0, 0)
	visible_pixels = array[:, :, 3] > 0
	array[:, :, 3][visible_pixels] = 255
	return Image.fromarray(array)


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


def _despill_chroma_green(image: Image.Image) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	red = array[:, :, 0].astype(np.int16)
	green = array[:, :, 1].astype(np.int16)
	blue = array[:, :, 2].astype(np.int16)
	strong_green = alpha & (green >= 150) & (red <= 115) & (blue <= 115) & (green >= red + 45)
	array[strong_green] = (0, 0, 0, 0)

	remaining_alpha = array[:, :, 3] > 0
	red = array[:, :, 0].astype(np.int16)
	green = array[:, :, 1].astype(np.int16)
	blue = array[:, :, 2].astype(np.int16)
	green_bias = remaining_alpha & (green > red + 14) & (green > blue + 14)
	clamped_green = np.maximum(red, blue) + 10
	array[:, :, 1][green_bias] = np.minimum(array[:, :, 1][green_bias], clamped_green[green_bias]).astype(np.uint8)
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


def _detect_grid_source_frames(source: Image.Image) -> list[list[DetectedFrame]]:
	alpha = np.array(source.getchannel("A"), dtype=np.uint8) > 0
	rows: list[list[DetectedFrame]] = []
	for row_index in range(SOURCE_ROWS):
		row: list[DetectedFrame] = []
		cell_top = round(row_index * source.height / SOURCE_ROWS)
		cell_bottom = round((row_index + 1) * source.height / SOURCE_ROWS)
		for column in range(SOURCE_COLUMNS):
			cell_left = round(column * source.width / SOURCE_COLUMNS)
			cell_right = round((column + 1) * source.width / SOURCE_COLUMNS)
			cell_alpha = alpha[cell_top:cell_bottom, cell_left:cell_right]
			if not cell_alpha.any():
				raise ValueError("Linglan grid cell %d,%d contains no visible pixels." % (column, row_index))
			local_y, local_x = np.nonzero(cell_alpha)
			left = int(local_x.min() + cell_left)
			top = int(local_y.min() + cell_top)
			right = int(local_x.max() + cell_left + 1)
			bottom = int(local_y.max() + cell_top + 1)
			alpha_pixels = int(cell_alpha.sum())
			if alpha_pixels < MIN_COMPONENT_ALPHA_PIXELS:
				raise ValueError("Linglan grid cell %d,%d contains too little foreground alpha." % (column, row_index))
			row.append(DetectedFrame((left, top, right, bottom), alpha_pixels))
		rows.append(row)
	return rows


def _largest_mask_component_bbox(mask: np.ndarray) -> tuple[int, int, int, int] | None:
	labels, count = ndimage.label(mask)
	if count <= 0:
		return None
	component_sizes = ndimage.sum(mask, labels, index=range(1, count + 1))
	largest_label = int(np.argmax(component_sizes)) + 1
	component = labels == largest_label
	y, x = np.nonzero(component)
	if x.size == 0 or y.size == 0:
		return None
	return int(x.min()), int(y.min()), int(x.max() + 1), int(y.max() + 1)


def _detect_linglan_body_anchor(source: Image.Image, frame: DetectedFrame) -> tuple[float, float]:
	left, top, right, bottom = frame.source_bbox
	cell = np.array(source.crop(frame.source_bbox).convert("RGBA"), dtype=np.uint8)
	alpha = cell[:, :, 3] > 0
	if not alpha.any():
		return ((left + right) * 0.5, float(bottom))

	red = cell[:, :, 0].astype(np.int16)
	green = cell[:, :, 1].astype(np.int16)
	blue = cell[:, :, 2].astype(np.int16)
	teal_skirt = (
		alpha
		& (red <= 190)
		& (green >= 80)
		& (blue >= 70)
		& (green >= red + 8)
		& (blue >= red + 4)
		& (np.abs(green - blue) <= 95)
	)
	body_bbox = _largest_mask_component_bbox(teal_skirt)
	if body_bbox is not None:
		body_left, _body_top, body_right, _body_bottom = body_bbox
		anchor_x = left + (body_left + body_right) * 0.5
	else:
		anchor_x = (left + right) * 0.5

	width = right - left
	local_anchor_x = anchor_x - left
	band_half_width = max(14, int(width * 0.22))
	band_left = max(0, int(round(local_anchor_x - band_half_width)))
	band_right = min(width, int(round(local_anchor_x + band_half_width + 1)))
	central_alpha = alpha[:, band_left:band_right]
	central_y, _central_x = np.nonzero(central_alpha)
	anchor_y = float(top + int(central_y.max()) + 1) if central_y.size > 0 else float(bottom)
	return anchor_x, anchor_y


def _compute_frame_layout(
	frames_by_name: OrderedDict[str, DetectedFrame],
	anchors_by_name: dict[str, tuple[float, float]],
) -> tuple[tuple[int, int], tuple[int, int]]:
	max_left_extent = 0.0
	max_right_extent = 0.0
	max_top_extent = 0.0
	max_bottom_extent = 0.0
	for frame_name, frame in frames_by_name.items():
		left, top, right, bottom = frame.source_bbox
		anchor_x, anchor_y = anchors_by_name[frame_name]
		max_left_extent = max(max_left_extent, anchor_x - left)
		max_right_extent = max(max_right_extent, right - anchor_x)
		max_top_extent = max(max_top_extent, anchor_y - top)
		max_bottom_extent = max(max_bottom_extent, bottom - anchor_y)

	horizontal_extent = max(max_left_extent, max_right_extent)
	frame_width = _round_up(int(math.ceil(horizontal_extent * 2 + FRAME_PADDING * 2)), FRAME_SIZE_ALIGNMENT)
	frame_height = _round_up(
		int(math.ceil(max_top_extent + max_bottom_extent + FRAME_PADDING * 2)),
		FRAME_SIZE_ALIGNMENT,
	)
	target_anchor = (
		frame_width // 2,
		FRAME_PADDING + int(math.ceil(max_top_extent)),
	)
	return (frame_width, frame_height), target_anchor


def _extract_frame(
	image: Image.Image,
	frame: DetectedFrame,
	frame_size: tuple[int, int],
	source_anchor: tuple[float, float],
	target_anchor: tuple[int, int],
) -> Image.Image:
	left, top, right, bottom = frame.source_bbox
	cell = image.crop(frame.source_bbox)
	result = Image.new("RGBA", frame_size, (0, 0, 0, 0))
	local_anchor_x = source_anchor[0] - left
	local_anchor_y = source_anchor[1] - top
	x = int(round(target_anchor[0] - local_anchor_x))
	y = int(round(target_anchor[1] - local_anchor_y))
	if x < 0 or y < 0 or x + cell.width > frame_size[0] or y + cell.height > frame_size[1]:
		raise ValueError(
			"Linglan frame does not fit anchored canvas: "
			f"bbox={frame.source_bbox}, canvas={frame_size}, offset=({x}, {y})."
		)
	result.alpha_composite(cell, (x, y))
	return result


def _keep_largest_alpha_component(image: Image.Image) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	labels, count = ndimage.label(alpha)
	if count <= 1:
		return image
	component_sizes = ndimage.sum(alpha, labels, index=range(1, count + 1))
	largest_label = int(np.argmax(component_sizes)) + 1
	array[labels != largest_label] = (0, 0, 0, 0)
	return Image.fromarray(array)


def _remove_tiny_alpha_components(image: Image.Image, min_alpha_pixels: int = 24) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	labels, count = ndimage.label(alpha)
	if count <= 1:
		return image
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		if int((labels[slices] == label_index).sum()) < min_alpha_pixels:
			array[labels == label_index] = (0, 0, 0, 0)
	return Image.fromarray(array)


def _remove_tall_edge_fragments(image: Image.Image) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	alpha = array[:, :, 3] > 0
	labels, count = ndimage.label(alpha)
	if count <= 1:
		return image
	edge_margin = 36
	for label_index, slices in enumerate(ndimage.find_objects(labels), start=1):
		if slices is None:
			continue
		left = int(slices[1].start)
		right = int(slices[1].stop)
		top = int(slices[0].start)
		bottom = int(slices[0].stop)
		width = right - left
		height = bottom - top
		touches_edge = left < edge_margin or right > image.width - edge_margin
		if touches_edge and width <= 10 and height >= 28:
			array[labels == label_index] = (0, 0, 0, 0)
	return Image.fromarray(array)


def _detect_animation_strip_source_frames(source: Image.Image, animation_name: str) -> list[DetectedFrame]:
	alpha = np.array(source.getchannel("A"), dtype=np.uint8) > 0
	frames: list[DetectedFrame] = []
	for column in range(SOURCE_COLUMNS):
		cell_left = round(column * source.width / SOURCE_COLUMNS)
		cell_right = round((column + 1) * source.width / SOURCE_COLUMNS)
		cell_alpha = alpha[:, cell_left:cell_right]
		if not cell_alpha.any():
			raise ValueError(f"Linglan {animation_name} frame {column} contains no visible pixels.")
		local_y, local_x = np.nonzero(cell_alpha)
		left = int(local_x.min() + cell_left)
		top = int(local_y.min())
		right = int(local_x.max() + cell_left + 1)
		bottom = int(local_y.max() + 1)
		alpha_pixels = int(cell_alpha.sum())
		if alpha_pixels < MIN_COMPONENT_ALPHA_PIXELS:
			raise ValueError(f"Linglan {animation_name} frame {column} contains too little foreground alpha.")
		frames.append(DetectedFrame((left, top, right, bottom), alpha_pixels))
	return frames


def _collect_linglan_frames(
	sources_by_animation: OrderedDict[str, Image.Image],
) -> tuple[OrderedDict[str, list[tuple[str, Image.Image]]], OrderedDict[str, list[str]]]:
	detected_by_name: OrderedDict[str, DetectedFrame] = OrderedDict()
	source_by_name: dict[str, Image.Image] = {}
	for animation_name, source in sources_by_animation.items():
		source_frames = _detect_animation_strip_source_frames(source, animation_name)
		for column in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{column}"
			detected_by_name[frame_name] = source_frames[column]
			source_by_name[frame_name] = source

	for frame_name, detected in detected_by_name.items():
		if detected.alpha_pixels < MIN_COMPONENT_ALPHA_PIXELS:
			raise ValueError("%s contains too little foreground alpha." % frame_name)

	anchors_by_name = {
		frame_name: _detect_linglan_body_anchor(source_by_name[frame_name], detected)
		for frame_name, detected in detected_by_name.items()
	}
	frame_size, target_anchor = _compute_frame_layout(detected_by_name, anchors_by_name)
	frames_by_animation: OrderedDict[str, list[tuple[str, Image.Image]]] = OrderedDict()
	animations: OrderedDict[str, list[str]] = OrderedDict()

	for animation_name, source in sources_by_animation.items():
		frames_by_animation[animation_name] = []
		frame_names: list[str] = []
		for column in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{column}"
			frame_image = _extract_frame(
				source_by_name[frame_name],
				detected_by_name[frame_name],
				frame_size,
				anchors_by_name[frame_name],
				target_anchor,
			)
			frame_image = _remove_tiny_alpha_components(frame_image)
			frames_by_animation[animation_name].append((frame_name, frame_image))
			frame_names.append(frame_name)
		animations[animation_name] = frame_names

	print(f"Linglan frame canvas: {frame_size[0]}x{frame_size[1]}")
	return frames_by_animation, animations


def _build_animation_strip(frames: list[tuple[str, Image.Image]]) -> tuple[Image.Image, dict[str, FrameRegion]]:
	frame_width = frames[0][1].width
	frame_height = frames[0][1].height
	sheet = Image.new("RGBA", (frame_width * len(frames), frame_height), (0, 0, 0, 0))
	regions: dict[str, FrameRegion] = {}
	for index, (frame_name, frame) in enumerate(frames):
		x = index * frame_width
		y = 0
		sheet.alpha_composite(frame, (x, y))
		regions[frame_name] = (x, y, frame_width, frame_height)
	return sheet, regions


def _animation_speed(animation_name: str) -> float:
	if animation_name.startswith("idle"):
		return 6.0
	if animation_name == "fly":
		return 10.0
	if animation_name == "explode":
		return 18.0
	if animation_name == "die":
		return 8.0
	return 9.0


def _animation_loop(animation_name: str) -> bool:
	return animation_name not in ("die", "explode")


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


def _write_spriteframes_for_animation_strips(
	output_path: Path,
	texture_resources: OrderedDict[str, str],
	regions_by_animation: OrderedDict[str, dict[str, FrameRegion]],
	animations: OrderedDict[str, list[str]],
	frames_uid: str | None = None,
) -> None:
	header = (
		f'[gd_resource type="SpriteFrames" format=3 uid="{frames_uid}"]'
		if frames_uid
		else '[gd_resource type="SpriteFrames" format=3]'
	)
	lines = [header, ""]

	for animation_name, texture_resource in texture_resources.items():
		texture_uid = LINGLAN_TEXTURE_UIDS.get(animation_name)
		texture_id = f"{animation_name}_texture"
		if texture_uid:
			lines.append(
				f'[ext_resource type="Texture2D" uid="{texture_uid}" '
				f'path="{texture_resource}" id="{texture_id}"]'
			)
		else:
			lines.append(f'[ext_resource type="Texture2D" path="{texture_resource}" id="{texture_id}"]')
	lines.append("")

	for animation_name, regions in regions_by_animation.items():
		texture_id = f"{animation_name}_texture"
		for frame_name, region in regions.items():
			lines.extend(
				[
					f'[sub_resource type="AtlasTexture" id="AtlasTexture_{frame_name}"]',
					f'atlas = ExtResource("{texture_id}")',
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
	print(f"SpriteFrames: {output_path} ({len(animations)} animations, {len(texture_resources)} textures)")


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


def _detect_visible_x_bands(image: Image.Image, expected_count: int) -> list[tuple[int, int]]:
	alpha = np.array(image.getchannel("A"), dtype=np.uint8) > 0
	occupied_columns = np.where(alpha.any(axis=0))[0]
	if occupied_columns.size == 0:
		raise ValueError("Linglan die source has no visible pixels after background removal.")

	bands: list[tuple[int, int]] = []
	start = int(occupied_columns[0])
	previous = int(occupied_columns[0])
	for column in occupied_columns[1:]:
		column = int(column)
		if column - previous > LINGLAN_DIE_BAND_GAP:
			bands.append((start, previous + 1))
			start = column
		previous = column
	bands.append((start, previous + 1))

	if len(bands) != expected_count:
		raise ValueError(f"Expected {expected_count} Linglan die bands, detected {len(bands)}: {bands}.")
	return bands


def _paste_clipped(target: Image.Image, source: Image.Image, offset: tuple[int, int]) -> None:
	x, y = offset
	source_left = max(0, -x)
	source_top = max(0, -y)
	target_x = max(0, x)
	target_y = max(0, y)
	width = min(source.width - source_left, target.width - target_x)
	height = min(source.height - source_top, target.height - target_y)
	if width <= 0 or height <= 0:
		return
	target.alpha_composite(
		source.crop((source_left, source_top, source_left + width, source_top + height)),
		(target_x, target_y),
	)


def _process_linglan_die(root: Path) -> tuple[dict[str, FrameRegion], list[str]]:
	source = Image.open(root / DIE_SOURCE).convert("RGBA")
	alpha = _despill_chroma_green(_remove_global_green_background(source))
	alpha = _remove_tiny_alpha_components(alpha, 12)
	alpha_path = root / DIE_ALPHA
	alpha_path.parent.mkdir(parents=True, exist_ok=True)
	alpha.save(alpha_path)

	bands = _detect_visible_x_bands(alpha, SOURCE_COLUMNS)
	frame_width, frame_height = LINGLAN_AUTHORED_FRAME_SIZE
	sheet = Image.new("RGBA", (frame_width * SOURCE_COLUMNS, frame_height), (0, 0, 0, 0))
	regions: dict[str, FrameRegion] = {}
	frame_names: list[str] = []
	last_body_anchor_x: float | None = None

	for index, (band_left, band_right) in enumerate(bands):
		band = alpha.crop((band_left, 0, band_right, alpha.height))
		band = _remove_tiny_alpha_components(band, 12)
		bbox = _foreground_bbox(band)
		alpha_pixels = int((np.array(band.getchannel("A"), dtype=np.uint8) > 0).sum())
		source_anchor_x, source_anchor_y = _detect_linglan_body_anchor(
			band,
			DetectedFrame(bbox, alpha_pixels),
		)
		if index <= 4:
			last_body_anchor_x = source_anchor_x

		crop = band.crop(bbox)
		if index <= 5:
			scale = min(
				LINGLAN_DIE_BASE_SCALE,
				(frame_width - 12) / max(crop.width, 1),
				(frame_height - 6) / max(crop.height, 1),
			)
			anchor_x = source_anchor_x if index <= 4 else (last_body_anchor_x or source_anchor_x)
			anchor_y = source_anchor_y
			new_size = (
				max(1, int(round(crop.width * scale))),
				max(1, int(round(crop.height * scale))),
			)
			resized = crop.resize(new_size, Image.Resampling.LANCZOS)
			local_anchor = (
				(anchor_x - bbox[0]) * scale,
				(anchor_y - bbox[1]) * scale,
			)
			offset = (
				int(round(LINGLAN_DIE_TARGET_ANCHOR[0] - local_anchor[0])),
				int(round(LINGLAN_DIE_TARGET_ANCHOR[1] - local_anchor[1])),
			)
		else:
			scale = min(
				LINGLAN_DIE_BASE_SCALE,
				(frame_width - 40) / max(crop.width, 1),
				(frame_height - 36) / max(crop.height, 1),
			)
			new_size = (
				max(1, int(round(crop.width * scale))),
				max(1, int(round(crop.height * scale))),
			)
			resized = crop.resize(new_size, Image.Resampling.LANCZOS)
			offset_y = int(round(208 - new_size[1] * 0.5))
			offset_y = max(12, min(offset_y, frame_height - 12 - new_size[1]))
			offset = (
				int(round(frame_width * 0.5 - new_size[0] * 0.5)),
				offset_y,
			)

		frame = Image.new("RGBA", LINGLAN_AUTHORED_FRAME_SIZE, (0, 0, 0, 0))
		_paste_clipped(frame, resized, offset)
		frame_name = f"die_{index}"
		x = index * frame_width
		sheet.alpha_composite(frame, (x, 0))
		regions[frame_name] = (x, 0, frame_width, frame_height)
		frame_names.append(frame_name)

	die_path = root / OUTPUT_DIE
	die_path.parent.mkdir(parents=True, exist_ok=True)
	sheet.save(die_path)
	print(f"Linglan die alpha: {alpha_path} ({alpha.width}x{alpha.height})")
	print(f"Linglan die strip: {die_path} ({sheet.width}x{sheet.height})")
	return regions, frame_names


def _collect_linglan_output_strip_regions(
	root: Path,
) -> tuple[OrderedDict[str, dict[str, FrameRegion]], OrderedDict[str, list[str]]]:
	regions_by_animation: OrderedDict[str, dict[str, FrameRegion]] = OrderedDict()
	animations: OrderedDict[str, list[str]] = OrderedDict()
	for animation_name, texture_resource in LINGLAN_TEXTURE_RESOURCES.items():
		texture_path = root / texture_resource.removeprefix("res://")
		image = Image.open(texture_path)
		if image.width % SOURCE_COLUMNS != 0:
			raise ValueError(f"{texture_path} width must divide into {SOURCE_COLUMNS} Linglan frames.")
		frame_width = image.width // SOURCE_COLUMNS
		frame_height = image.height
		if (frame_width, frame_height) != LINGLAN_AUTHORED_FRAME_SIZE:
			raise ValueError(
				f"{texture_path} must use authored Linglan frame size "
				f"{LINGLAN_AUTHORED_FRAME_SIZE}, got {(frame_width, frame_height)}."
			)

		regions: dict[str, FrameRegion] = {}
		frame_names: list[str] = []
		for frame_index in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{frame_index}"
			regions[frame_name] = (frame_index * frame_width, 0, frame_width, frame_height)
			frame_names.append(frame_name)
		regions_by_animation[animation_name] = regions
		animations[animation_name] = frame_names
	return regions_by_animation, animations


def _process_linglan_sprite(root: Path) -> None:
	_process_linglan_die(root)
	regions_by_animation, animations = _collect_linglan_output_strip_regions(root)
	_write_spriteframes_for_animation_strips(
		root / OUTPUT_FRAMES,
		LINGLAN_TEXTURE_RESOURCES,
		regions_by_animation,
		animations,
		SPRITE_FRAMES_UID,
	)


def _fit_foreground_on_canvas(
	image: Image.Image,
	canvas_size: tuple[int, int],
	max_foreground_size: tuple[int, int],
	padding: int = 0,
	resampling: Image.Resampling = Image.Resampling.LANCZOS,
) -> Image.Image:
	left, top, right, bottom = _foreground_bbox(image, padding)
	crop = image.crop((left, top, right, bottom))
	scale = min(
		max_foreground_size[0] / max(crop.width, 1),
		max_foreground_size[1] / max(crop.height, 1),
	)
	new_size = (
		max(1, int(round(crop.width * scale))),
		max(1, int(round(crop.height * scale))),
	)
	resized = crop.resize(new_size, resampling)
	result = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
	result.alpha_composite(
		resized,
		(
			(canvas_size[0] - resized.width) // 2,
			(canvas_size[1] - resized.height) // 2,
		),
	)
	return result


def _process_skill2_rocket(root: Path) -> None:
	source = Image.open(root / SKILL2_ROCKET_SOURCE)
	alpha = _despill_chroma_green(_remove_global_green_background(source))
	alpha_path = root / SKILL2_ROCKET_ALPHA
	alpha_path.parent.mkdir(parents=True, exist_ok=True)
	alpha.save(alpha_path)

	rocket = _fit_foreground_on_canvas(
		alpha,
		SKILL2_ROCKET_FRAME_SIZE,
		SKILL2_ROCKET_MAX_FOREGROUND_SIZE,
		8,
		Image.Resampling.LANCZOS,
	)
	rocket = _despill_chroma_green(rocket)
	rocket_path = root / OUTPUT_SKILL2_ROCKET
	rocket_path.parent.mkdir(parents=True, exist_ok=True)
	rocket.save(rocket_path)

	regions = {"fly_0": (0, 0, rocket.width, rocket.height)}
	_write_spriteframes(
		root / OUTPUT_SKILL2_ROCKET_FRAMES,
		SKILL2_ROCKET_TEXTURE_RESOURCE,
		regions,
		OrderedDict([("fly", ["fly_0"])]),
	)
	print(f"Skill2 rocket: {rocket_path} ({rocket.width}x{rocket.height})")


def _process_skill2_explosion(root: Path) -> None:
	source = Image.open(root / SKILL2_EXPLOSION_SOURCE)
	alpha = _despill_chroma_green(_remove_global_green_background(source))
	alpha_path = root / SKILL2_EXPLOSION_ALPHA
	alpha_path.parent.mkdir(parents=True, exist_ok=True)
	alpha.save(alpha_path)

	frame_width, frame_height = SKILL2_EXPLOSION_FRAME_SIZE
	sheet = Image.new(
		"RGBA",
		(frame_width * SKILL2_EXPLOSION_COLUMNS, frame_height * SKILL2_EXPLOSION_ROWS),
		(0, 0, 0, 0),
	)
	regions: dict[str, FrameRegion] = {}
	frame_names: list[str] = []
	for row in range(SKILL2_EXPLOSION_ROWS):
		cell_top = round(row * alpha.height / SKILL2_EXPLOSION_ROWS)
		cell_bottom = round((row + 1) * alpha.height / SKILL2_EXPLOSION_ROWS)
		for column in range(SKILL2_EXPLOSION_COLUMNS):
			cell_left = round(column * alpha.width / SKILL2_EXPLOSION_COLUMNS)
			cell_right = round((column + 1) * alpha.width / SKILL2_EXPLOSION_COLUMNS)
			cell = alpha.crop((cell_left, cell_top, cell_right, cell_bottom))
			if cell.getchannel("A").getbbox() is None:
				raise ValueError(f"Skill2 explosion cell {column},{row} has no foreground.")
			frame = cell.resize(SKILL2_EXPLOSION_FRAME_SIZE, Image.Resampling.LANCZOS)
			frame = _despill_chroma_green(frame)
			frame_index = row * SKILL2_EXPLOSION_COLUMNS + column
			frame_name = f"explode_{frame_index}"
			x = column * frame_width
			y = row * frame_height
			sheet.alpha_composite(frame, (x, y))
			regions[frame_name] = (x, y, frame_width, frame_height)
			frame_names.append(frame_name)

	explosion_path = root / OUTPUT_SKILL2_EXPLOSION
	explosion_path.parent.mkdir(parents=True, exist_ok=True)
	sheet.save(explosion_path)
	_write_spriteframes(
		root / OUTPUT_SKILL2_EXPLOSION_FRAMES,
		SKILL2_EXPLOSION_TEXTURE_RESOURCE,
		regions,
		OrderedDict([("explode", frame_names)]),
	)
	print(f"Skill2 explosion: {explosion_path} ({sheet.width}x{sheet.height})")


def _process_skill2(root: Path) -> None:
	_process_skill2_rocket(root)
	_process_skill2_explosion(root)


def main() -> None:
	parser = argparse.ArgumentParser(description="Build Linglan boss raster assets.")
	parser.add_argument(
		"--only",
		choices=("all", "sprite", "hud", "vfx", "skill2"),
		default="all",
		help="Limit processing to one asset group.",
	)
	args = parser.parse_args()

	root = Path(__file__).resolve().parents[1]
	if args.only in ("all", "sprite"):
		_process_linglan_sprite(root)
	if args.only in ("all", "hud"):
		_process_hud(root)
	if args.only in ("all", "vfx"):
		_process_vfx(root)
	if args.only in ("all", "skill2"):
		_process_skill2(root)


if __name__ == "__main__":
	main()
