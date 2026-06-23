#!/usr/bin/env python3
"""Build inventory item detail UI textures from generated flat UI sources."""

from __future__ import annotations

from pathlib import Path

from PIL import Image

from connected_background_remover import ConnectedBackgroundOptions, remove_connected_background


PANEL_SOURCE = "dev_assets/source_images/item_detail_panel_pixel_generated.png"
BADGE_SOURCE = "dev_assets/source_images/item_category_badge_pixel_generated.png"
PANEL_OUTPUT = "resources/texture/item_detail_panel_bg.png"
COLLECTIBLE_BADGE_OUTPUT = "resources/texture/item_category_badge_collectible.png"
ITEM_BADGE_OUTPUT = "resources/texture/item_category_badge_item.png"

PANEL_SIZE = (242, 148)
BADGE_SIZE = (58, 22)
BACKGROUND_RGB_TOLERANCE = 72
BACKGROUND_HUE_TOLERANCE = 0.045
BACKGROUND_EXPANSION_RADIUS = 8


def _remove_connected_chroma_background(image: Image.Image) -> Image.Image:
	return remove_connected_background(
		image,
		ConnectedBackgroundOptions(
			rgb_tolerance=BACKGROUND_RGB_TOLERANCE,
			hue_tolerance=BACKGROUND_HUE_TOLERANCE,
			expansion_radius=BACKGROUND_EXPANSION_RADIUS,
		),
	)


def _crop_visible(image: Image.Image) -> Image.Image:
	bbox = image.getchannel("A").getbbox()
	if bbox is None:
		raise ValueError("Generated UI source contains no visible pixels.")
	return image.crop(bbox)


def _resize_pixel_ui(image: Image.Image, size: tuple[int, int]) -> Image.Image:
	return image.resize(size, Image.Resampling.LANCZOS)


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
	panel_source = _crop_visible(_remove_connected_chroma_background(Image.open(root / PANEL_SOURCE)))
	panel = _resize_pixel_ui(panel_source, PANEL_SIZE)
	panel.save(root / PANEL_OUTPUT)
	print(f"Item detail panel: {root / PANEL_OUTPUT} ({panel.width}x{panel.height})")

	badge_source = _crop_visible(_remove_connected_chroma_background(Image.open(root / BADGE_SOURCE)))
	badge = _resize_pixel_ui(badge_source, BADGE_SIZE)
	collectible_badge = _tint_badge(badge, (66, 210, 181), 0.12)
	item_badge = _tint_badge(badge, (218, 161, 70), 0.18)
	collectible_badge.save(root / COLLECTIBLE_BADGE_OUTPUT)
	item_badge.save(root / ITEM_BADGE_OUTPUT)
	print(f"Collectible badge: {root / COLLECTIBLE_BADGE_OUTPUT} ({collectible_badge.width}x{collectible_badge.height})")
	print(f"Item badge: {root / ITEM_BADGE_OUTPUT} ({item_badge.width}x{item_badge.height})")


if __name__ == "__main__":
	main()
