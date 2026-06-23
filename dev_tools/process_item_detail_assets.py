#!/usr/bin/env python3
"""Build inventory item detail UI textures from generated pixel-art sources."""

from __future__ import annotations

from collections import deque
from pathlib import Path

from PIL import Image


PANEL_SOURCE = "dev_assets/source_images/item_detail_panel_pixel_generated.png"
BADGE_SOURCE = "dev_assets/source_images/item_category_badge_pixel_generated.png"
PANEL_OUTPUT = "resources/texture/item_detail_panel_bg.png"
COLLECTIBLE_BADGE_OUTPUT = "resources/texture/item_category_badge_collectible.png"
ITEM_BADGE_OUTPUT = "resources/texture/item_category_badge_item.png"

PANEL_SIZE = (242, 148)
BADGE_SIZE = (58, 22)


def _is_light_checker(pixel: tuple[int, int, int, int]) -> bool:
	red, green, blue, alpha = pixel
	if alpha == 0:
		return True
	return min(red, green, blue) >= 206 and max(red, green, blue) - min(red, green, blue) <= 34


def _remove_connected_light_background(image: Image.Image) -> Image.Image:
	rgba = image.convert("RGBA")
	pixels = rgba.load()
	width, height = rgba.size
	visited = bytearray(width * height)
	queue: deque[tuple[int, int]] = deque()

	def enqueue_if_background(x: int, y: int) -> None:
		index = y * width + x
		if visited[index] != 0:
			return
		if not _is_light_checker(pixels[x, y]):
			return
		visited[index] = 1
		queue.append((x, y))

	for x in range(width):
		enqueue_if_background(x, 0)
		enqueue_if_background(x, height - 1)
	for y in range(height):
		enqueue_if_background(0, y)
		enqueue_if_background(width - 1, y)

	while queue:
		x, y = queue.popleft()
		for neighbor_x in range(x - 1, x + 2):
			for neighbor_y in range(y - 1, y + 2):
				if neighbor_x == x and neighbor_y == y:
					continue
				if 0 <= neighbor_x < width and 0 <= neighbor_y < height:
					enqueue_if_background(neighbor_x, neighbor_y)

	for y in range(height):
		for x in range(width):
			if visited[y * width + x] != 0:
				pixels[x, y] = (0, 0, 0, 0)
			else:
				red, green, blue, alpha = pixels[x, y]
				pixels[x, y] = (red, green, blue, 255 if alpha > 0 else 0)
	return rgba


def _crop_visible(image: Image.Image) -> Image.Image:
	bbox = image.getchannel("A").getbbox()
	if bbox is None:
		raise ValueError("Generated UI source contains no visible pixels.")
	return image.crop(bbox)


def _resize_pixel_ui(image: Image.Image, size: tuple[int, int]) -> Image.Image:
	return image.resize(size, Image.Resampling.BOX)


def _crop_to_aspect(image: Image.Image, target_aspect: float) -> Image.Image:
	width, height = image.size
	current_aspect = width / float(height)
	if current_aspect > target_aspect:
		new_width = round(height * target_aspect)
		left = (width - new_width) // 2
		return image.crop((left, 0, left + new_width, height))
	new_height = round(width / target_aspect)
	top = (height - new_height) // 2
	return image.crop((0, top, width, top + new_height))


def _tint_badge(image: Image.Image, tint: tuple[int, int, int], amount: float) -> Image.Image:
	rgba = image.convert("RGBA")
	pixels = rgba.load()
	for y in range(rgba.height):
		for x in range(rgba.width):
			red, green, blue, alpha = pixels[x, y]
			if alpha == 0:
				continue
			luma = (red * 0.299 + green * 0.587 + blue * 0.114) / 255.0
			if luma < 0.18:
				continue
			pixels[x, y] = (
				round(red * (1.0 - amount) + tint[0] * amount),
				round(green * (1.0 - amount) + tint[1] * amount),
				round(blue * (1.0 - amount) + tint[2] * amount),
				alpha,
			)
	return rgba


def main() -> None:
	root = Path(__file__).resolve().parents[1]
	panel_source = _crop_visible(_remove_connected_light_background(Image.open(root / PANEL_SOURCE)))
	panel = _resize_pixel_ui(panel_source, PANEL_SIZE)
	panel.save(root / PANEL_OUTPUT)
	print(f"Item detail panel: {root / PANEL_OUTPUT} ({panel.width}x{panel.height})")

	badge_source = _crop_to_aspect(
		_crop_visible(_remove_connected_light_background(Image.open(root / BADGE_SOURCE))),
		BADGE_SIZE[0] / float(BADGE_SIZE[1]),
	)
	badge = _resize_pixel_ui(badge_source, BADGE_SIZE)
	collectible_badge = _tint_badge(badge, (66, 210, 181), 0.12)
	item_badge = _tint_badge(badge, (218, 161, 70), 0.18)
	collectible_badge.save(root / COLLECTIBLE_BADGE_OUTPUT)
	item_badge.save(root / ITEM_BADGE_OUTPUT)
	print(f"Collectible badge: {root / COLLECTIBLE_BADGE_OUTPUT} ({collectible_badge.width}x{collectible_badge.height})")
	print(f"Item badge: {root / ITEM_BADGE_OUTPUT} ({item_badge.width}x{item_badge.height})")


if __name__ == "__main__":
	main()
