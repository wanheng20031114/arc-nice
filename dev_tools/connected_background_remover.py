#!/usr/bin/env python3
"""Remove sampled-color backgrounds by radius-expanded connected masking.

This is intended for generated pixel art sheets where the background is a
nearly flat color, but small antialiasing gaps can leave color islands that are
not reachable by ordinary 4/8-neighbor flood fill.

Usage:
  python connected_background_remover.py INPUT OUTPUT
  python connected_background_remover.py INPUT OUTPUT --sample 0,0 --radius 10
  python connected_background_remover.py INPUT OUTPUT --rgb-tolerance 88 --hue-tolerance 0.04
"""

from __future__ import annotations

import argparse
import colorsys
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


@dataclass(frozen=True)
class ConnectedBackgroundOptions:
	sample: tuple[int, int] = (0, 0)
	rgb_tolerance: int = 88
	hue_tolerance: float = 0.04
	expansion_radius: int = 10
	use_hue: bool = True
	min_hue_saturation: float = 0.45
	min_hue_value: float = 0.10
	green_ratio_limit: float = 0.62
	harden_alpha: bool = True


def _rgb_to_hsv_arrays(rgb_float: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
	red = rgb_float[:, :, 0]
	green = rgb_float[:, :, 1]
	blue = rgb_float[:, :, 2]
	max_channel = np.maximum(np.maximum(red, green), blue)
	min_channel = np.minimum(np.minimum(red, green), blue)
	delta = max_channel - min_channel
	hue = np.zeros_like(max_channel)

	non_gray = delta > 0.0001
	red_is_max = non_gray & (red >= green) & (red >= blue)
	green_is_max = non_gray & (green > red) & (green >= blue)
	blue_is_max = non_gray & (blue > red) & (blue > green)
	hue[red_is_max] = ((green[red_is_max] - blue[red_is_max]) / delta[red_is_max]) % 6.0
	hue[green_is_max] = ((blue[green_is_max] - red[green_is_max]) / delta[green_is_max]) + 2.0
	hue[blue_is_max] = ((red[blue_is_max] - green[blue_is_max]) / delta[blue_is_max]) + 4.0
	hue /= 6.0

	saturation = np.zeros_like(max_channel)
	visible = max_channel > 0.0001
	saturation[visible] = delta[visible] / max_channel[visible]
	return hue, saturation, max_channel


def build_sample_background_mask(
	array: np.ndarray,
	options: ConnectedBackgroundOptions,
) -> np.ndarray:
	height, width = array.shape[:2]
	sample_x = max(0, min(options.sample[0], width - 1))
	sample_y = max(0, min(options.sample[1], height - 1))
	key = tuple(int(value) for value in array[sample_y, sample_x, :3])
	key_hue, key_saturation, _key_value = colorsys.rgb_to_hsv(
		key[0] / 255.0,
		key[1] / 255.0,
		key[2] / 255.0,
	)

	rgb = array[:, :, :3].astype(np.int16)
	key_array = np.array(key, dtype=np.int16)
	box_mask = np.all(np.abs(rgb - key_array) <= options.rgb_tolerance, axis=2)
	if not options.use_hue or key_saturation < options.min_hue_saturation:
		return box_mask

	rgb_float = array[:, :, :3].astype(np.float32) / 255.0
	hue, saturation, value = _rgb_to_hsv_arrays(rgb_float)
	hue_distance = np.minimum(np.abs(hue - key_hue), 1.0 - np.abs(hue - key_hue))
	red = rgb_float[:, :, 0]
	green = rgb_float[:, :, 1]
	blue = rgb_float[:, :, 2]
	hue_mask = (
		(saturation >= options.min_hue_saturation)
		& (value >= options.min_hue_value)
		& (hue_distance <= options.hue_tolerance)
		& (green <= np.maximum(red, blue) * options.green_ratio_limit)
	)
	return box_mask | hue_mask


def expand_connected_mask(candidate_mask: np.ndarray, expansion_radius: int) -> np.ndarray:
	seeds = np.zeros(candidate_mask.shape, dtype=bool)
	seeds[0, :] = candidate_mask[0, :]
	seeds[-1, :] = candidate_mask[-1, :]
	seeds[:, 0] = candidate_mask[:, 0]
	seeds[:, -1] = candidate_mask[:, -1]

	structure_size = max(0, expansion_radius) * 2 + 1
	return ndimage.binary_dilation(
		seeds,
		structure=np.ones((structure_size, structure_size), dtype=bool),
		mask=candidate_mask,
		iterations=-1,
	)


def remove_connected_background(
	image: Image.Image,
	options: ConnectedBackgroundOptions | None = None,
) -> Image.Image:
	options = options if options is not None else ConnectedBackgroundOptions()
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	candidate_mask = build_sample_background_mask(array, options)
	connected_background = expand_connected_mask(candidate_mask, options.expansion_radius)

	array[connected_background] = (0, 0, 0, 0)
	if options.harden_alpha:
		visible_pixels = (~connected_background) & (array[:, :, 3] > 0)
		array[:, :, 3][visible_pixels] = 255
	return Image.fromarray(array)


def _parse_sample(value: str) -> tuple[int, int]:
	parts = value.split(",")
	if len(parts) != 2:
		raise argparse.ArgumentTypeError("sample must be formatted as x,y")
	try:
		return int(parts[0]), int(parts[1])
	except ValueError as exc:
		raise argparse.ArgumentTypeError("sample coordinates must be integers") from exc


def main() -> None:
	parser = argparse.ArgumentParser(
		description="Remove border-connected sampled-color backgrounds from generated sprites",
	)
	parser.add_argument("input_path", help="Input image path")
	parser.add_argument("output_path", help="Output PNG path")
	parser.add_argument("--sample", type=_parse_sample, default=(0, 0), help="Background sample pixel as x,y")
	parser.add_argument("--rgb-tolerance", type=int, default=88, help="RGB box tolerance around the sampled color")
	parser.add_argument("--hue-tolerance", type=float, default=0.04, help="Hue distance tolerance for saturated backgrounds")
	parser.add_argument("--radius", type=int, default=10, help="Square expansion radius for connected background growth")
	parser.add_argument("--disable-hue", action="store_true", help="Only use RGB tolerance, not hue-based background matching")
	parser.add_argument("--preserve-alpha", action="store_true", help="Do not harden remaining visible pixels to alpha 255")
	args = parser.parse_args()

	input_path = Path(args.input_path)
	if not input_path.is_file():
		print(f"Error: file does not exist - {input_path}", file=sys.stderr)
		raise SystemExit(1)

	output_path = Path(args.output_path)
	output_path.parent.mkdir(parents=True, exist_ok=True)
	options = ConnectedBackgroundOptions(
		sample=args.sample,
		rgb_tolerance=max(0, min(args.rgb_tolerance, 255)),
		hue_tolerance=max(0.0, min(args.hue_tolerance, 0.5)),
		expansion_radius=max(0, args.radius),
		use_hue=not args.disable_hue,
		harden_alpha=not args.preserve_alpha,
	)
	result = remove_connected_background(Image.open(input_path), options)
	result.save(output_path)

	alpha = result.getchannel("A")
	histogram = alpha.histogram()
	print(f"Input:              {input_path}")
	print(f"Output:             {output_path}")
	print(f"Output size:        {result.width}x{result.height}")
	print(f"Foreground bbox:    {alpha.getbbox()}")
	print(f"Transparent pixels: {histogram[0]}")
	print(f"Opaque pixels:      {histogram[255]}")


if __name__ == "__main__":
	main()
