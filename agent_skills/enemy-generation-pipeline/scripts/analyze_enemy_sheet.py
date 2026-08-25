#!/usr/bin/env python3
"""Analyze a generated enemy sprite sheet for anchors and Atlas regions."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


def _parse_size(value: str) -> tuple[int, int]:
	parts = value.lower().replace(",", "x").split("x")
	if len(parts) != 2:
		raise argparse.ArgumentTypeError("Expected WIDTHxHEIGHT.")
	return (int(parts[0]), int(parts[1]))


def _parse_color(value: str) -> tuple[int, int, int]:
	text = value.strip()
	if text.startswith("#"):
		text = text[1:]
		if len(text) != 6:
			raise argparse.ArgumentTypeError("Expected #RRGGBB.")
		return (int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16))
	parts = text.split(",")
	if len(parts) != 3:
		raise argparse.ArgumentTypeError("Expected R,G,B or #RRGGBB.")
	return tuple(int(part) for part in parts)  # type: ignore[return-value]


def _rect_from_bbox(bbox: tuple[int, int, int, int] | None) -> dict[str, int] | None:
	if bbox is None:
		return None
	return {
		"x": bbox[0],
		"y": bbox[1],
		"width": bbox[2] - bbox[0],
		"height": bbox[3] - bbox[1],
	}


def _grid_cell_bounds(width: int, height: int, columns: int, rows: int, column: int, row: int) -> tuple[int, int, int, int]:
	return (
		round(column * width / float(columns)),
		round(row * height / float(rows)),
		round((column + 1) * width / float(columns)),
		round((row + 1) * height / float(rows)),
	)


def _visible_mask(image: Image.Image) -> np.ndarray:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	if array[:, :, 3].min() < 255:
		return array[:, :, 3] > 0
	raise ValueError("Sprite sheets must use ImageGen's native transparent background.")


def _dominant_colors(image: Image.Image, mask: np.ndarray, limit: int) -> list[dict[str, object]]:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	pixels = array[:, :, :3][mask]
	if len(pixels) == 0:
		return []
	quantized = (pixels // 16) * 16
	counts = Counter(map(tuple, quantized.tolist())).most_common(limit)
	total = float(len(pixels))
	return [
		{
			"rgb": [int(channel) for channel in color],
			"hex": "#%02x%02x%02x" % tuple(int(channel) for channel in color),
			"ratio": round(count / total, 4),
		}
		for color, count in counts
	]


def _largest_bbox(mask: np.ndarray) -> tuple[int, int, int, int] | None:
	if not mask.any():
		return None
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


def _mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int] | None:
	if not mask.any():
		return None
	ys, xs = np.nonzero(mask)
	return (int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1))


def _body_mask(image: Image.Image, visible: np.ndarray, body_rgb: tuple[int, int, int] | None, threshold: float) -> np.ndarray:
	if body_rgb is None:
		return visible
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	rgb = array[:, :, :3].astype(np.int16)
	target = np.array(body_rgb, dtype=np.int16)
	distance = np.linalg.norm(rgb - target, axis=2)
	return visible & (distance <= threshold)


def _intersect_region(
	target: tuple[int, int, int, int],
	cell: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
	left = max(target[0], cell[0])
	top = max(target[1], cell[1])
	right = min(target[0] + target[2], cell[2])
	bottom = min(target[1] + target[3], cell[3])
	if left >= right or top >= bottom:
		return (target[0], target[1], 0, 0)
	return (left, top, right - left, bottom - top)


def _frame_data(
	image: Image.Image,
	visible: np.ndarray,
	body: np.ndarray,
	columns: int,
	rows: int,
	virtual_size: tuple[int, int] | None,
	body_anchor: tuple[int, int] | None,
	safe_padding: int,
) -> list[dict[str, object]]:
	frames: list[dict[str, object]] = []
	for row in range(rows):
		for column in range(columns):
			cell = _grid_cell_bounds(image.width, image.height, columns, rows, column, row)
			left, top, right, bottom = cell
			cell_visible = visible[top:bottom, left:right]
			cell_body = body[top:bottom, left:right]
			alpha_bbox = _mask_bbox(cell_visible)
			body_bbox = _largest_bbox(cell_body) or alpha_bbox
			if body_bbox is None:
				anchor = (round((right - left) * 0.5, 2), round((bottom - top) * 0.5, 2))
				global_anchor = (round(left + anchor[0], 2), round(top + anchor[1], 2))
			else:
				anchor = (
					round((body_bbox[0] + body_bbox[2]) * 0.5, 2),
					round(float(body_bbox[3]), 2),
				)
				global_anchor = (round(left + anchor[0], 2), round(top + anchor[1], 2))

			frame: dict[str, object] = {
				"row": row,
				"column": column,
				"cell": {"x": left, "y": top, "width": right - left, "height": bottom - top},
				"alpha_bbox": _rect_from_bbox(alpha_bbox),
				"body_bbox": _rect_from_bbox(body_bbox),
				"body_anchor_in_cell": list(anchor),
				"body_anchor_global": list(global_anchor),
			}
			if alpha_bbox is not None:
				padding = {
					"left": int(alpha_bbox[0]),
					"top": int(alpha_bbox[1]),
					"right": int((right - left) - alpha_bbox[2]),
					"bottom": int((bottom - top) - alpha_bbox[3]),
				}
				frame["cell_safety_padding"] = padding
				frame["cell_safety_padding_min"] = min(padding.values())
				frame["cell_safety_ok"] = min(padding.values()) >= safe_padding
			if body_bbox is not None:
				frame["body_size"] = [int(body_bbox[2] - body_bbox[0]), int(body_bbox[3] - body_bbox[1])]
				frame["body_center_in_cell"] = [
					round((body_bbox[0] + body_bbox[2]) * 0.5, 2),
					round((body_bbox[1] + body_bbox[3]) * 0.5, 2),
				]
			if virtual_size is not None and body_anchor is not None:
				target = (
					round(global_anchor[0] - body_anchor[0]),
					round(global_anchor[1] - body_anchor[1]),
					virtual_size[0],
					virtual_size[1],
				)
				region = _intersect_region(target, cell)
				margin = (
					region[0] - target[0],
					region[1] - target[1],
					virtual_size[0] - region[2],
					virtual_size[1] - region[3],
				)
				frame["atlas_target_region"] = _rect_from_tuple(target)
				frame["atlas_region"] = _rect_from_tuple(region)
				frame["atlas_margin"] = _rect_from_tuple(margin)
				frame["logical_size"] = list(virtual_size)
			frames.append(frame)
	return frames


def _range_summary(values: list[float]) -> dict[str, float] | None:
	if not values:
		return None
	return {
		"min": round(min(values), 2),
		"max": round(max(values), 2),
		"range": round(max(values) - min(values), 2),
	}


def _summarize_frames(frames: list[dict[str, object]], safe_padding: int) -> dict[str, object]:
	body_widths: list[float] = []
	body_heights: list[float] = []
	anchor_x: list[float] = []
	anchor_y: list[float] = []
	safety_minimums: list[float] = []
	safety_violations: list[dict[str, object]] = []
	for frame in frames:
		body_size = frame.get("body_size")
		if isinstance(body_size, list) and len(body_size) == 2:
			body_widths.append(float(body_size[0]))
			body_heights.append(float(body_size[1]))
		anchor = frame.get("body_anchor_in_cell")
		if isinstance(anchor, list) and len(anchor) == 2:
			anchor_x.append(float(anchor[0]))
			anchor_y.append(float(anchor[1]))
		safety_min = frame.get("cell_safety_padding_min")
		if isinstance(safety_min, (int, float)):
			safety_minimums.append(float(safety_min))
			if float(safety_min) < safe_padding:
				safety_violations.append(
					{
						"row": frame.get("row"),
						"column": frame.get("column"),
						"minimum_padding": safety_min,
					}
				)
	return {
		"body_width": _range_summary(body_widths),
		"body_height": _range_summary(body_heights),
		"body_anchor_x": _range_summary(anchor_x),
		"body_anchor_y": _range_summary(anchor_y),
		"minimum_cell_safety_padding": _range_summary(safety_minimums),
		"required_safe_padding": safe_padding,
		"safety_violations": safety_violations,
	}


def _rect_from_tuple(rect: tuple[int, int, int, int]) -> dict[str, int]:
	return {"x": rect[0], "y": rect[1], "width": rect[2], "height": rect[3]}


def _load_image(path: Path) -> Image.Image:
	if not path.is_file():
		raise FileNotFoundError(path)
	return Image.open(path).convert("RGBA")


def main() -> None:
	parser = argparse.ArgumentParser(description="Analyze a transparent enemy sprite sheet for color and anchor slicing.")
	parser.add_argument("image", type=Path)
	parser.add_argument("--grid", type=_parse_size, required=True, help="Actual sheet grid as COLUMNSxROWS. Pass the real frame layout for this asset.")
	parser.add_argument("--body-rgb", type=_parse_color, default=None, help="Stable body color as R,G,B or #RRGGBB.")
	parser.add_argument("--body-threshold", type=float, default=70.0, help="RGB distance threshold for body mask.")
	parser.add_argument("--virtual-size", type=_parse_size, default=None, help="Logical AtlasTexture size as WIDTHxHEIGHT.")
	parser.add_argument("--body-anchor", type=_parse_size, default=None, help="Body anchor inside logical frame as XxY.")
	parser.add_argument("--safe-padding", type=int, default=8, help="Required empty pixels around visible bbox inside each grid cell.")
	parser.add_argument("--dominant-colors", type=int, default=10)
	args = parser.parse_args()

	image = _load_image(args.image)
	visible = _visible_mask(image)
	body = _body_mask(image, visible, args.body_rgb, args.body_threshold)
	sheet_bbox = _mask_bbox(visible)
	frames = _frame_data(
		image,
		visible,
		body,
		args.grid[0],
		args.grid[1],
		args.virtual_size,
		args.body_anchor,
		args.safe_padding,
	)
	result = {
		"image": str(args.image),
		"size": [image.width, image.height],
		"visible_bbox": _rect_from_bbox(sheet_bbox),
		"dominant_colors": _dominant_colors(image, visible, args.dominant_colors),
		"summary": _summarize_frames(frames, args.safe_padding),
		"frames": frames,
	}
	print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
	main()
