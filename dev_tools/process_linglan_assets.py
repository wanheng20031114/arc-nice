#!/usr/bin/env python3
"""Build Linglan boss sprite sheet and SpriteFrames from a generated source sheet."""

from __future__ import annotations

from collections import OrderedDict
from pathlib import Path

from PIL import Image

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


def _grid_bounds(total: int, parts: int, index: int) -> tuple[int, int]:
	start = round(index * total / float(parts))
	end = round((index + 1) * total / float(parts))
	return start, end


def _extract_cell(image: Image.Image, column: int, row: int, frame_size: tuple[int, int]) -> Image.Image:
	left, right = _grid_bounds(image.width, SOURCE_COLUMNS, column)
	top, bottom = _grid_bounds(image.height, SOURCE_ROWS, row)
	cell = image.crop((left, top, right, bottom))
	result = Image.new("RGBA", frame_size, (0, 0, 0, 0))
	result.alpha_composite(cell, ((frame_size[0] - cell.width) // 2, (frame_size[1] - cell.height) // 2))
	return result


def _collect_frames(source: Image.Image) -> tuple[list[tuple[str, Image.Image]], OrderedDict[str, list[str]]]:
	cell_width = max(
		_grid_bounds(source.width, SOURCE_COLUMNS, column)[1] - _grid_bounds(source.width, SOURCE_COLUMNS, column)[0]
		for column in range(SOURCE_COLUMNS)
	)
	cell_height = max(
		_grid_bounds(source.height, SOURCE_ROWS, row)[1] - _grid_bounds(source.height, SOURCE_ROWS, row)[0]
		for row in range(SOURCE_ROWS)
	)
	frame_size = (cell_width, cell_height)
	frames: list[tuple[str, Image.Image]] = []
	animations: OrderedDict[str, list[str]] = OrderedDict()

	for animation_name, row in ANIMATION_ROWS.items():
		frame_names: list[str] = []
		for column in range(SOURCE_COLUMNS):
			frame_name = f"{animation_name}_{column}"
			frames.append((frame_name, _extract_cell(source, column, row, frame_size)))
			frame_names.append(frame_name)
		animations[animation_name] = frame_names

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
