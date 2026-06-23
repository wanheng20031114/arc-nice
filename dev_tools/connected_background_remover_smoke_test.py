#!/usr/bin/env python3
"""Smoke test for connected_background_remover.py."""

from __future__ import annotations

from PIL import Image

from connected_background_remover import ConnectedBackgroundOptions, remove_connected_background


def _expect(condition: bool, message: str) -> None:
	if not condition:
		raise AssertionError(message)


def main() -> None:
	background = (234, 10, 226, 255)
	subject = (248, 192, 72, 255)
	outline = (28, 22, 24, 255)
	image = Image.new("RGBA", (80, 80), background)
	pixels = image.load()

	for y in range(18, 62):
		for x in range(18, 62):
			pixels[x, y] = subject
	for x in range(18, 62):
		pixels[x, 18] = outline
		pixels[x, 61] = outline
	for y in range(18, 62):
		pixels[18, y] = outline
		pixels[61, y] = outline

	# This patch is not 8-neighbor connected to the outer background, but it is
	# close enough to be reached by the radius-expanded connected background.
	for y in range(28, 34):
		for x in range(22, 28):
			pixels[x, y] = background

	# This one is deeply enclosed and should survive as foreground detail.
	for y in range(39, 43):
		for x in range(39, 43):
			pixels[x, y] = background

	result = remove_connected_background(
		image,
		ConnectedBackgroundOptions(
			rgb_tolerance=88,
			hue_tolerance=0.04,
			expansion_radius=10,
		),
	)

	_expect(result.getpixel((0, 0))[3] == 0, "Border background must become transparent.")
	_expect(result.getpixel((24, 30))[3] == 0, "Near disconnected background patch must be removed.")
	_expect(result.getpixel((40, 40))[3] == 255, "Deep enclosed sampled-color foreground detail must remain.")
	_expect(result.getpixel((30, 30))[3] == 255, "Subject body must remain visible.")
	print("CONNECTED_BACKGROUND_REMOVER_SMOKE_TEST_OK")


if __name__ == "__main__":
	main()
