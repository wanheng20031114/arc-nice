#!/usr/bin/env python3
"""Build Linglan boss sprite sheet and SpriteFrames from a generated source sheet."""

from __future__ import annotations

from dataclasses import dataclass
from collections import OrderedDict
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from connected_background_remover import ConnectedBackgroundOptions, remove_connected_background


SOURCE_SHEET = "dev_assets/source_images/linglan_boss_sheet_generated.png"
ALPHA_SHEET = "dev_assets/source_images/linglan_boss_sheet_alpha.png"
OUTPUT_TEXTURE = "resources/texture/linglan.png"
OUTPUT_FRAMES = "resources/animation/linglan.tres"
TEXTURE_RESOURCE = "res://resources/texture/linglan.png"

SOURCE_COLUMNS = 4
SOURCE_ROWS = 6
BACKGROUND_TOLERANCE = 88
BACKGROUND_HUE_TOLERANCE = 0.04
BACKGROUND_EXPANSION_RADIUS = 10
FRAME_GROUP_RADIUS = 4
FRAME_PADDING = 12
FRAME_SIZE_ALIGNMENT = 8
MIN_FRAME_ALPHA_PIXELS = 1000

ANIMATION_ROWS: OrderedDict[str, int] = OrderedDict(
	[
		("idle", 0),
		("move_down", 1),
		("move_left", 2),
		("move_right", 3),
		("move_up", 4),
		("die", 5),
	]
)

IDLE_DIRECTIONS = {
	"idle_down": "idle_0",
	"idle_left": "move_left_0",
	"idle_right": "move_right_0",
	"idle_up": "move_up_0",
}


FrameRegion = tuple[int, int, int, int]


@dataclass(frozen=True)
class DetectedFrame:
	source_bbox: tuple[int, int, int, int]
	alpha_pixels: int


def _round_up(value: int, alignment: int) -> int:
	return ((value + alignment - 1) // alignment) * alignment


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
		if alpha_pixels < MIN_FRAME_ALPHA_PIXELS:
			continue
		local_y, local_x = np.nonzero(component_alpha)
		top_offset = slices[0].start
		left_offset = slices[1].start
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


def _compute_frame_size(rows: list[list[DetectedFrame]]) -> tuple[int, int]:
	boxes = [frame.source_bbox for row in rows for frame in row]
	max_width = max(right - left for left, _top, right, _bottom in boxes)
	max_height = max(bottom - top for _left, top, _right, bottom in boxes)
	return (
		_round_up(max_width + FRAME_PADDING * 2, FRAME_SIZE_ALIGNMENT),
		_round_up(max_height + FRAME_PADDING * 2, FRAME_SIZE_ALIGNMENT),
	)


def _extract_frame(image: Image.Image, frame: DetectedFrame, frame_size: tuple[int, int]) -> Image.Image:
	cell = image.crop(frame.source_bbox)
	result = Image.new("RGBA", frame_size, (0, 0, 0, 0))
	result.alpha_composite(cell, ((frame_size[0] - cell.width) // 2, (frame_size[1] - cell.height) // 2))
	return result


def _collect_frames(source: Image.Image) -> tuple[list[tuple[str, Image.Image]], OrderedDict[str, list[str]]]:
	source_rows = _detect_source_frames(source)
	frame_size = _compute_frame_size(source_rows)
	frames: list[tuple[str, Image.Image]] = []
	animations: OrderedDict[str, list[str]] = OrderedDict()

	for row_index, animation_name in enumerate(ANIMATION_ROWS.keys()):
		frame_names: list[str] = []
		for column in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{column}"
			source_frame = source_rows[row_index][column]
			frames.append((frame_name, _extract_frame(source, source_frame, frame_size)))
			frame_names.append(frame_name)
		animations[animation_name] = frame_names
		print(
			"%s bboxes: %s"
			% (
				animation_name,
				", ".join(str(frame.source_bbox) for frame in source_rows[row_index]),
			)
		)
	print(f"Linglan frame canvas: {frame_size[0]}x{frame_size[1]}")

	for animation_name, frame_name in IDLE_DIRECTIONS.items():
		animations[animation_name] = [frame_name]

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
		return 4.0
	if animation_name == "die":
		return 7.0
	return 8.0


def _animation_loop(animation_name: str) -> bool:
	return animation_name != "die"


def _write_animation_resource(
	output_path: Path,
	texture_path: str,
	regions: dict[str, FrameRegion],
	animations: OrderedDict[str, list[str]],
) -> None:
	lines = [
		'[gd_resource type="SpriteFrames" format=3]',
		"",
		f'[ext_resource type="Texture2D" path="{texture_path}" id="1_texture"]',
		"",
	]
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
	print(f"Linglan animation: {output_path} ({len(animations)} animations)")


def main() -> None:
	root = Path(__file__).resolve().parents[1]
	source_path = root / SOURCE_SHEET
	source = Image.open(source_path)
	alpha_source = remove_connected_background(
		source,
		ConnectedBackgroundOptions(
			rgb_tolerance=BACKGROUND_TOLERANCE,
			hue_tolerance=BACKGROUND_HUE_TOLERANCE,
			expansion_radius=BACKGROUND_EXPANSION_RADIUS,
		),
	)

	alpha_path = root / ALPHA_SHEET
	alpha_path.parent.mkdir(parents=True, exist_ok=True)
	alpha_source.save(alpha_path)
	print(f"Linglan alpha source: {alpha_path} ({alpha_source.width}x{alpha_source.height})")

	frames, animations = _collect_frames(alpha_source)
	sheet, regions = _build_sheet(frames)

	sheet_path = root / OUTPUT_TEXTURE
	sheet_path.parent.mkdir(parents=True, exist_ok=True)
	sheet.save(sheet_path)
	print(f"Linglan sheet: {sheet_path} ({sheet.width}x{sheet.height})")

	_write_animation_resource(root / OUTPUT_FRAMES, TEXTURE_RESOURCE, regions, animations)


if __name__ == "__main__":
	main()
