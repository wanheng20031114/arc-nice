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
	CAPOO_FRAME_SIZE,
	DEBUG_DIR,
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


def _crop_grid_cell(sheet: Image.Image, column: int, row: int) -> Image.Image:
	cell_width = sheet.width / float(GRID_COLUMNS)
	cell_height = sheet.height / float(GRID_ROWS)
	left = round(column * cell_width)
	top = round(row * cell_height)
	right = round((column + 1) * cell_width)
	bottom = round((row + 1) * cell_height)
	return sheet.crop((left, top, right, bottom))


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


def process_capoo(name: str) -> None:
	source_config = SINGLE_SOURCES.get(name)
	if source_config == None:
		raise ValueError(f"Unsupported single Capoo: {name}")
	source_path = source_config["path"]
	if not source_path.is_file():
		raise FileNotFoundError(source_path)

	TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
	ANIMATION_DIR.mkdir(parents=True, exist_ok=True)
	DEBUG_DIR.mkdir(parents=True, exist_ok=True)

	alpha_source = _remove_chroma_background(Image.open(source_path), str(source_config["key"]))
	_save_debug(f"{name}_single_alpha", alpha_source)
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
